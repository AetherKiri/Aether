#include "systemnnn_runtime.h"
#include "engine_runtime_provider.h"
#include "emberfall/sdl_presentation.hpp"
#include "emberfall/sdl_settings.hpp"
#include "emberfall/system_progress.hpp"
#include "save_bank.h"
#include <SDL.h>
#include <nlohmann/json.hpp>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <sstream>

namespace aether::systemnnn {
namespace {
namespace fs = std::filesystem;
using namespace emberfall::scene;
using emberfall::sdl::Presentation;
using emberfall::sdl::SettingsPage;
using emberfall::sdl::GameText;
using emberfall::sdl::Config;
using emberfall::sdl::Button;
using emberfall::render::Surface;
using Mode = nnn::RuntimeMode;

enum class Menu { None, System, Save, Load, Overwrite, Settings, Backlog, Extras, Notice };
constexpr int slots_per_page = 6;

class Runtime {
public:
    explicit Runtime(const engine_runtime_host_v1_t &host) : host_(host) {}
    ~Runtime() {
        if (progress_loaded_) {
            try { SaveProgress(); }
            catch (const std::exception &e) {
                if (host_.log) host_.log(host_.user_data, ENGINE_RUNTIME_LOG_ERROR, "systemnnn", e.what());
            }
        }
        CloseMovie();
        if (audio_) SDL_CloseAudioDevice(audio_);
        if (audio_initialized_) SDL_QuitSubSystem(SDL_INIT_AUDIO);
    }

    void Open(const char *path, const char *entry) {
        root_ = fs::canonical(fs::u8path(path));
        if (!fs::is_directory(root_)) root_ = root_.parent_path();
        const auto scripts = nnn::resource::find_directory(root_, "spt");
        if (nnn::resource::find_file(scripts, "sys.spt").empty()) throw std::runtime_error("Missing spt/sys.spt");
#ifdef __ANDROID__
        if (android_player && (!entry || !*entry)) {
            static std::atomic<uint64_t> next{0};
            ticket_ = std::to_string(++next);
            const auto request = nlohmann::json{{"path", root_.string()}, {"ticket", ticket_}}.dump();
            host_.platform_request(host_.user_data, "systemnnn_player", request.c_str());
            return;
        }
#endif
        saves_ = std::make_unique<SaveBank>(root_);
        presentation_ = std::make_unique<Presentation>(root_, font);
        options_.queue_audio_events = false;
        options_.audio.sample_rate = 48000;
        options_.filename_encoder = GameText::Filename;
        if (entry && *entry) {
            fs::path selected = fs::u8path(entry);
            if (selected.is_relative()) selected = selected.has_parent_path() ? root_ / selected : scripts / selected;
            selected = fs::canonical(selected);
            if (selected.parent_path() != scripts || nnn::game_config::ascii_lower(selected.extension().string()) != ".spt")
                throw std::invalid_argument("SystemNNN startup script must be in the game's spt directory");
            options_.entry = selected.filename().string();
        }
        game_ = NewGame();
        saves_->Configure(*game_, root_);
        const auto global = saves_->directory / "emberfall-sdl.progress";
        if (fs::exists(global)) emberfall::sdl::RestoreSystemProgress(*game_->runtime(), SaveBank::Read(global));
        previous_progress_ = emberfall::sdl::SystemProgress(*game_->runtime());
        progress_loaded_ = true;
        if (!entry || !*entry) EnterTitle();
        else { title_ = false; presentation_->ResetStory(); }
        OpenAudio();
        Tick(0);
    }

    void Tick(uint32_t ms) {
        if (paused_) return;
        if (exit_) throw std::runtime_error("Runtime requested termination");
        if (!ticket_.empty()) return;
        if (movie_ && PollMovie()) return;
        if (settings_) {
            if (const auto *frame = settings_->Frame(ms)) PublishPixels(*frame);
            return;
        }
        if (menu_ == Menu::None) {
            if (title_) {
                presentation_->UpdateTitle(*game_, input_, ms);
                dirty_ = dirty_ || game_->needs_redraw();
            } else {
                input_.play_movies = true;
                input_.advance = input_.advance || game_->skip_effective() || game_->auto_ready(ms, game_->text_complete());
                const auto &state = game_->step_frame({ms, game_->pace(ms)}, input_);
                if (state.wait == Wait::Error) throw std::runtime_error(state.error);
                if (game_->take_system_save_request()) SaveProgress();
                if (state.wait == Wait::Movie) StartMovie(state.movie);
                if (state.wait == Wait::Ended) {
                    if (state.end_reason == EndReason::Exit) { Exit(); return; }
                    EnterTitle();
                }
            }
        }
        input_.advance = false;
        input_.choice = 0;
        if (title_) {
            if (!dirty_) return;
            Publish(presentation_->TitleSurface(*game_));
            game_->after_present();
        } else {
            presentation_->Story(*game_, menu_ == Menu::None ? ms : 0, dirty_, [&](const Surface &surface) { Publish(surface); });
        }
        dirty_ = false;
    }

    void Pause(bool paused) {
        if (paused && progress_loaded_) SaveProgress();
        paused_ = paused;
        if (audio_) SDL_PauseAudioDevice(audio_, paused);
        if (movie_) {
            const auto *api = Media();
            (paused ? api->pause : api->play)(api->user_data, movie_);
        }
        input_ = {};
        if (settings_) settings_->Point(SettingsPage::Pointer::Cancel, -1, -1);
        if (game_) { game_->set_ctrl_skip(false); game_->reset_frame_pacing(); }
    }

    void Input(const engine_input_event_t &event) {
        if (paused_ || !game_) return;
        if (settings_) { SettingsInput(event); return; }
        if (event.type == ENGINE_INPUT_EVENT_POINTER_MOVE || event.type == ENGINE_INPUT_EVENT_POINTER_DOWN ||
            event.type == ENGINE_INPUT_EVENT_POINTER_UP) {
            input_.mouse_x = int(std::clamp(event.x, -32768.0, 32768.0));
            input_.mouse_y = int(std::clamp(event.y, -32768.0, 32768.0));
            const auto index = Hit(input_.mouse_x, input_.mouse_y);
            if (!buttons_.empty() && selection_ != index) { selection_ = index; dirty_ = true; }
            if (event.type == ENGINE_INPUT_EVENT_POINTER_DOWN) {
                pressed_ = index;
                input_.held = true;
            } else if (event.type == ENGINE_INPUT_EVENT_POINTER_UP) {
                const bool valid = input_.held && !(event.modifiers & ENGINE_INPUT_MODIFIER_POINTER_CANCEL);
                input_.held = false;
                if (valid && event.button == 1) Back();
                else if (valid && (buttons_.empty() || (index >= 0 && pressed_ == index))) Confirm();
                pressed_ = -1;
            }
            return;
        }
        if (event.type == ENGINE_INPUT_EVENT_BACK) { Back(); return; }
        if (event.key_code == 17 && (event.type == ENGINE_INPUT_EVENT_KEY_DOWN || event.type == ENGINE_INPUT_EVENT_KEY_UP))
            game_->set_ctrl_skip(event.type == ENGINE_INPUT_EVENT_KEY_DOWN);
        if (event.type != ENGINE_INPUT_EVENT_KEY_DOWN || (event.modifiers & 0x80)) return;
        switch (event.key_code) {
        case 13: case 32: Confirm(); break;
        case 27: Back(); break;
        case 37: case 38: Move(-1); break;
        case 39: case 40: Move(1); break;
        case 0x74: if (CanSave()) TrySlot(true, saves_->quick); break; // F5
        case 0x78: if (fs::is_regular_file(saves_->Slot(saves_->quick))) TrySlot(false, saves_->quick); break; // F9
        default:
            if (event.key_code >= '1' && event.key_code <= '9' && size_t(event.key_code - '1') < buttons_.size()) {
                selection_ = event.key_code - '1'; Confirm();
            }
        }
    }

    std::string Info() const {
        if (!game_) return R"({"runtime":"systemnnn","mode":"android-player"})";
        const auto &state = game_->state();
        auto audio = game_->audio().stats();
        return nlohmann::json{
            {"runtime", "systemnnn"}, {"mode", title_ ? "title" : "story"}, {"wait", int(state.wait)},
            {"script", state.script}, {"word", state.word}, {"message", state.dialogue.message_id},
            {"audio_peak", audio.peak}, {"audio_frames", audio.nonzero_frames}, {"menu", int(menu_)},
            {"settings_page", settings_ ? settings_->page() : 0},
            {"saves", saves_->directory.string()}, {"visible_characters", game_->visible_text()},
            {"text_complete", game_->text_complete()}
        }.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
    }

    engine_result_t PlayerClosed(std::string_view operation, std::string_view ticket) {
        if (operation != "systemnnn_closed" && operation != "systemnnn_launch_failed") return ENGINE_RESULT_NOT_SUPPORTED;
        if (ticket_.empty() || ticket != ticket_) return ENGINE_RESULT_INVALID_STATE;
        if (operation == "systemnnn_launch_failed") {
            error = "Android could not launch the SystemNNN player";
            if (host_.log) host_.log(host_.user_data, ENGINE_RUNTIME_LOG_ERROR, "systemnnn", error.c_str());
        }
        exit_ = true;
        return ENGINE_RESULT_OK;
    }

    bool android_player = false;
    std::string font, error;
    std::vector<uint8_t> rgba;
    uint32_t width = 0, height = 0;
    uint64_t serial = 0, delivered = 0;

private:
    std::unique_ptr<GameSession> NewGame() {
        auto game = std::make_unique<GameSession>(root_, options_);
        game->set_chart_storage(saves_->directory);
        return game;
    }

    void Replace(std::unique_ptr<GameSession> &candidate) {
        // The device only reads the upstream mixer. Retire its owner after
        // the current pull returns, without blocking audio during a slot load.
        if (audio_) SDL_LockAudioDevice(audio_);
        game_.swap(candidate);
        if (audio_) SDL_UnlockAudioDevice(audio_);
        options_.runtime = game_->runtime();
        options_.save_layout = game_->runtime_ref().save_layout;
        presentation_->ResetStory();
        buttons_.clear();
        menu_ = Menu::None;
        title_ = false;
        dirty_ = true;
    }

    void EnterTitle() {
        options_.runtime = game_->runtime();
        options_.save_layout = game_->runtime_ref().save_layout;
        auto candidate = NewGame();
        presentation_->StartTitle(*candidate);
        Replace(candidate);
        title_ = true;
        bool has_saves = false;
        for (const auto &item : fs::directory_iterator(saves_->directory)) {
            const auto name = nnn::game_config::ascii_lower(item.path().filename().string());
            if (name.size() > 4 && name.substr(name.size()-4) == ".sav") { has_saves = true; break; }
        }
        title_buttons_ = presentation_->TitleButtons(*game_, has_saves);
        selection_ = 0;
    }

    void StartStory() {
        auto candidate = NewGame();
        candidate->sync_runtime_names();
        Replace(candidate);
    }

    void OpenAudio() {
        audio_initialized_ = SDL_InitSubSystem(SDL_INIT_AUDIO) == 0;
        if (audio_initialized_) {
            SDL_AudioSpec spec{};
            spec.freq = int(options_.audio.sample_rate); spec.format = AUDIO_S16SYS;
            spec.channels = 2; spec.samples = 1024; spec.userdata = this;
            spec.callback = [](void *context, Uint8 *samples, int bytes) {
                static_cast<Runtime *>(context)->game_->audio().pull(reinterpret_cast<int16_t *>(samples), size_t(bytes) / 4);
            };
            audio_ = SDL_OpenAudioDevice(nullptr, 0, &spec, nullptr, 0);
        }
        if (audio_) SDL_PauseAudioDevice(audio_, 0);
        else if (host_.log) host_.log(host_.user_data, ENGINE_RUNTIME_LOG_WARNING, "systemnnn", SDL_GetError());
    }

    bool CanSave() const {
        if (title_) return false;
        const auto wait = game_->state().wait;
        return wait == Wait::Dialogue || wait == Wait::Choice || wait == Wait::Place ||
            (wait == Wait::NativePanel && game_->native_panel_can_save()) ||
            (wait == Wait::Modal && game_->modal_savable());
    }

    void SaveProgress() {
        auto bytes = emberfall::sdl::SystemProgress(*game_->runtime());
        if (bytes == previous_progress_) return;
        SaveBank::Write(saves_->directory / "emberfall-sdl.progress", bytes);
        previous_progress_.swap(bytes);
    }

    void TrySlot(bool save, int index) {
        try {
            const auto path = saves_->Slot(index);
            if (save) {
                SaveProgress();
                SaveBank::Write(path, game_->export_presented_pc_save());
            }
            else {
                const auto bytes = SaveBank::Read(path);
                auto staging = options_;
                staging.runtime = game_->runtime()->fork();
                auto candidate = std::make_unique<GameSession>(root_, staging);
                candidate->set_chart_storage(saves_->directory);
                candidate->load_pc_save_candidate(bytes, title_ ? nullptr : game_.get());
                Replace(candidate);
            }
            SetMenu(Menu::None);
        } catch (const std::exception &ex) {
            notice_ = ex.what();
            SetMenu(Menu::Notice);
        }
    }

    int Hit(int x, int y) const {
        for (size_t i = 0; i < buttons_.size(); ++i) {
            const auto r = buttons_[i].bounds;
            if (x >= r.x && x < r.x+r.width && y >= r.y && y < r.y+r.height) return int(i);
        }
        return -1;
    }

    void Move(int step) {
        if (buttons_.empty()) return;
        for (size_t i = 0; i < buttons_.size(); ++i) {
            selection_ = (selection_ + int(buttons_.size()) + step) % int(buttons_.size());
            if (buttons_[selection_].enabled) break;
        }
        dirty_ = true;
    }

    void SetMenu(Menu menu) {
        if (settings_) {
            SaveProgress();
            remembered_settings_page_ = settings_->page();
            settings_.reset();
            input_ = {};
        }
        if (menu == Menu::Settings) {
            game_->set_ctrl_skip(false);
            settings_ = SettingsPage::Open(*game_, *presentation_, remembered_settings_page_);
        }
        menu_ = menu;
        if (menu == Menu::Extras) {
            gallery_ = game_->unlocked_pictures();
            gallery_index_ = 0;
            if (!gallery_.empty()) gallery_picture_ = game_->ui_texture(gallery_.front());
        } else {
            gallery_.clear();
            gallery_picture_.reset();
        }
        dirty_ = true;
        buttons_.clear();
        selection_ = 0;
        pressed_ = -1;
    }

    void SettingsInput(const engine_input_event_t &event) {
        using Pointer = SettingsPage::Pointer;
        using Key = SettingsPage::Key;
        SettingsPage::Action action = SettingsPage::Action::None;
        const int x = int(std::clamp(event.x, -32768.0, 32768.0));
        const int y = int(std::clamp(event.y, -32768.0, 32768.0));
        switch (event.type) {
        case ENGINE_INPUT_EVENT_POINTER_DOWN:
            if (event.button != 1) settings_->Point(Pointer::Down, x, y);
            break;
        case ENGINE_INPUT_EVENT_POINTER_MOVE:
            settings_->Point(Pointer::Move, x, y);
            break;
        case ENGINE_INPUT_EVENT_POINTER_UP:
            if (event.modifiers & ENGINE_INPUT_MODIFIER_POINTER_CANCEL) settings_->Point(Pointer::Cancel, x, y);
            else if (event.button == 1) action = SettingsPage::Action::Close;
            else action = settings_->Point(Pointer::Up, x, y);
            break;
        case ENGINE_INPUT_EVENT_BACK: action = SettingsPage::Action::Close; break;
        case ENGINE_INPUT_EVENT_KEY_DOWN:
            switch (event.key_code) {
            case 27: action = SettingsPage::Action::Close; break;
            case 9: action = settings_->Press(event.modifiers & 1 ? Key::Previous : Key::Next); break;
            case 38: action = settings_->Press(Key::Previous); break;
            case 40: action = settings_->Press(Key::Next); break;
            case 37: action = settings_->Press(Key::Left); break;
            case 39: action = settings_->Press(Key::Right); break;
            case 13: case 32:
                if (!(event.modifiers & 0x80)) action = settings_->Press(Key::Confirm);
                break;
            }
            break;
        }
        if (action == SettingsPage::Action::Close) SetMenu(Menu::None);
        if ((action == SettingsPage::Action::Windowed || action == SettingsPage::Action::Fullscreen) && host_.platform_request)
            host_.platform_request(host_.user_data, "runtime_window_mode",
                action == SettingsPage::Action::Fullscreen ? "fullscreen" : "windowed");
    }

    void Back() {
        if (movie_) { if (movie_skippable_) CloseMovie(); return; }
        if (menu_ != Menu::None) { SetMenu(Menu::None); return; }
        if (!title_ && game_->state().wait == Wait::Modal && game_->state().modal) {
            game_->act_modal(game_->state().modal->request, 0, 0);
        } else if (!title_ && game_->state().wait == Wait::NativePanel) {
            game_->native_panel_input(input_.mouse_x, input_.mouse_y, false, true);
        } else SetMenu(Menu::System);
        dirty_ = true;
    }

    void Confirm() {
        if (movie_) { if (movie_skippable_) CloseMovie(); return; }
        if (buttons_.empty()) {
            if (!title_ && menu_ == Menu::None) input_.advance = game_->request_advance();
            return;
        }
        if (selection_ < 0 || size_t(selection_) >= buttons_.size() || !buttons_[selection_].enabled) return;
        const int value = buttons_[selection_].value;
        if (menu_ == Menu::None) {
            if (title_) {
                switch (value) {
                case 0: StartStory(); break;
                case 1: slot_page_ = 0; SetMenu(Menu::Load); break;
                case 2: SetMenu(Menu::Settings); break;
                case 3: SetMenu(Menu::Extras); break;
                case 4: Exit(); break;
                default: StartStory(); break;
                }
            } else if (const auto &modal = game_->state().modal) {
                game_->act_modal(modal->request, 1, value);
            } else input_.choice = unsigned(value);
        } else if (menu_ == Menu::Save || menu_ == Menu::Load) {
            if (value == -1 || value == -2) { slot_page_ += value == -1 ? -1 : 1; selection_ = 0; }
            else if (value == -3) SetMenu(Menu::None);
            else if (menu_ == Menu::Save && fs::exists(saves_->Slot(value))) {
                overwrite_ = value; SetMenu(Menu::Overwrite);
            } else TrySlot(menu_ == Menu::Save, value);
        } else if (menu_ == Menu::Extras && value != 2 && !gallery_.empty()) {
            const int next = std::clamp(gallery_index_ + (value == 0 ? -1 : 1), 0, int(gallery_.size()) - 1);
            gallery_picture_ = game_->ui_texture(gallery_[next]);
            gallery_index_ = next;
        } else if (menu_ == Menu::Overwrite) {
            if (value == 0) TrySlot(true, overwrite_);
            else SetMenu(Menu::Save);
        } else if (menu_ == Menu::System) {
            static constexpr Menu pages[]{Menu::None, Menu::Save, Menu::Load, Menu::Backlog, Menu::Settings};
            if (value < 5) { slot_page_ = 0; SetMenu(pages[value]); }
            else if (value == 5) EnterTitle();
            else Exit();
        } else if (menu_ == Menu::Settings && value < 3) {
            const auto parameter = value == 0 ? nnn::NNNPARAM_AUTOMODE : nnn::NNNPARAM_TOTALVOLUME;
            int setting = game_->get_system_parameter(parameter);
            game_->set_system_parameter(parameter, value == 0 ? !setting : std::clamp(setting + (value == 1 ? -10 : 10), 0, 100));
            game_->apply_runtime_parameters();
        } else SetMenu(Menu::None);
        dirty_ = true;
    }

    std::vector<Button> Buttons() {
        std::vector<std::string> labels;
        std::vector<int> ids;
        if (menu_ == Menu::None) {
            if (title_) return title_buttons_;
            const auto &state = game_->state();
            if (state.wait == Wait::Choice && state.selection) {
                for (const auto &option : state.selection->options) {
                    labels.push_back(presentation_->text.Decode(option));
                    ids.push_back(int(labels.size()));
                }
            } else if (state.wait == Wait::Place) {
                auto places = game_->places();
                for (size_t i = 0; i < places.size(); ++i) if (places[i] == 2) {
                    labels.push_back("Place " + std::to_string(i+1)); ids.push_back(int(i+1));
                }
            } else if (state.modal) {
                for (const auto &row : state.modal->rows) {
                    labels.push_back(presentation_->text.Decode(row.label, true)); ids.push_back(row.id);
                }
            }
        } else if (menu_ == Menu::Save || menu_ == Menu::Load) {
            for (int slot = slot_page_*slots_per_page; slot < std::min(saves_->count,(slot_page_+1)*slots_per_page); ++slot) {
                const auto path = saves_->Slot(slot);
                labels.push_back(std::to_string(slot+1) + (fs::is_regular_file(path) ? "   " + path.filename().string() : "   —"));
                ids.push_back(slot);
            }
            if (slot_page_ > 0) { labels.emplace_back("Previous page"); ids.push_back(-1); }
            if ((slot_page_+1)*slots_per_page < saves_->count) { labels.emplace_back("Next page"); ids.push_back(-2); }
            labels.emplace_back("Back"); ids.push_back(-3);
        } else if (menu_ == Menu::System) labels = {"Resume", "Save", "Load", "Backlog", "Settings", "Title", "Exit"};
        else if (menu_ == Menu::Settings) labels = {
            game_->get_system_parameter(nnn::NNNPARAM_AUTOMODE) ? "Auto advance: On" : "Auto advance: Off",
            "Volume −", "Volume + (" + std::to_string(game_->get_system_parameter(nnn::NNNPARAM_TOTALVOLUME)) + "%)", "Back"};
        else if (menu_ == Menu::Overwrite) labels = {"Overwrite slot " + std::to_string(overwrite_+1), "Cancel"};
        else if (menu_ == Menu::Notice) labels = {notice_, "Back"};
        else if (menu_ == Menu::Backlog) {
            const auto &log = game_->backlog();
            for (size_t i = log.size() > 6 ? log.size()-6 : 0; i < log.size(); ++i)
                labels.push_back(presentation_->text.Decode(log[i].text, log[i].configuration_text));
            labels.emplace_back("Back");
        } else if (menu_ == Menu::Extras) {
            if (gallery_.empty()) labels = {"No pictures unlocked", "Back"};
            else {
                auto items = presentation_->Rows({"Previous", std::to_string(gallery_index_ + 1) + "/" +
                    std::to_string(gallery_.size()) + "   Next", "Back"}, width, height);
                const int h = std::max(30, int(height) / 15);
                for (size_t i = 0; i < items.size(); ++i) {
                    items[i].bounds = {int(i*width/3), int(height)-h, int(width/3), h};
                }
                items[0].enabled = gallery_index_ > 0;
                items[1].enabled = size_t(gallery_index_ + 1) < gallery_.size();
                return items;
            }
        }
        auto result = presentation_->Rows(labels, width, height);
        for (size_t i = 0; i < ids.size(); ++i) {
            auto &b = result[i];
            b.value = ids[i];
            if (menu_ == Menu::Load && b.value >= 0) b.enabled = fs::is_regular_file(saves_->Slot(b.value));
        }
        if (menu_ == Menu::System) result[1].enabled = CanSave();
        return result;
    }

    void Publish(const Surface &surface) {
        width = surface.width; height = surface.height;
        buttons_ = Buttons();
        Surface overlay;
        if (!buttons_.empty()) {
            overlay = surface;
            if (gallery_picture_) {
                const auto &image = *gallery_picture_;
                emberfall::render::paint_rectangle(overlay, {0, 0, int(width), int(height)}, {0, 0, 0}, 100);
                emberfall::render::paint_texture(overlay, image, {0,0,image.canvas_width,image.canvas_height},
                    {(int(width)-image.canvas_width)/2, (int(height)-image.canvas_height)/2});
            }
            presentation_->PaintButtons(overlay, buttons_, selection_);
            PublishPixels(overlay);
        } else PublishPixels(surface);
    }

    void PublishPixels(const Surface &surface) {
        width = surface.width;
        height = surface.height;
        rgba.resize(size_t(width)*height*4);
        if (SDL_ConvertPixels(width, height, SDL_PIXELFORMAT_RGB24, surface.rgb.data(), width*3,
                              SDL_PIXELFORMAT_RGBA32, rgba.data(), width*4) != 0)
            throw std::runtime_error(SDL_GetError());
        ++serial;
    }

    const engine_runtime_media_host_v1_t *Media() const {
        return static_cast<const engine_runtime_media_host_v1_t *>(host_.reserved_ptr[1]);
    }
    void CloseMovie() {
        if (!movie_) return;
        Media()->destroy(Media()->user_data, movie_);
        movie_ = nullptr;
        dirty_ = true;
    }
    void StartMovie(unsigned index) {
        const auto list = nnn::game_config::read(root_, "spt", "movielist.xtx");
        std::istringstream rows(list);
        std::string line;
        for (unsigned i = 0; i < index && std::getline(rows,line); ++i) {
            if (i+1 != index) continue;
            size_t cursor = 0;
            auto token = nnn::game_config::name_token(line,cursor);
            if (!token) break;
            const auto path = nnn::resource::find_file(nnn::resource::find_directory(root_,"movie"), std::string(*token), GameText::Filename);
            const auto *api = Media();
            if (path.empty() || !api || !api->open || !api->play) break;
            if (api->open(api->user_data, path.c_str(), &movie_) != ENGINE_RESULT_OK) break;
            api->set_volume(api->user_data, movie_, game_->audio().movie_gain());
            if (api->play(api->user_data, movie_) != ENGINE_RESULT_OK) CloseMovie();
            else {
                Config config(nnn::game_config::read(root_,"init","printMovie.xtx"));
                movie_skippable_ = config.integer("noSkipFlag",0) == 0;
                movie_serial_ = UINT64_MAX;
                return;
            }
        }
        if (host_.log) host_.log(host_.user_data, ENGINE_RUNTIME_LOG_WARNING, "systemnnn", "Movie unavailable in this host");
    }
    bool PollMovie() {
        const auto *api = Media();
        engine_media_state_t state{};
        state.struct_size = sizeof(state);
        if (api->get_state(api->user_data, movie_, &state) != ENGINE_RESULT_OK ||
            state.status == ENGINE_MEDIA_STATUS_ERROR || state.status == ENGINE_MEDIA_STATUS_ENDED) {
            CloseMovie(); return false;
        }
        if (!state.frame_ready || state.frame_serial == movie_serial_) return true;
        if (!state.width || !state.height || uint64_t(state.width)*state.height > emberfall::render::max_pixels) {
            CloseMovie(); return false;
        }
        movie_pixels_.resize(size_t(state.width)*state.height*4);
        engine_frame_desc_t frame{}; frame.struct_size = sizeof(frame);
        if (api->read_frame_rgba(api->user_data, movie_, movie_pixels_.data(), movie_pixels_.size(), &frame) == ENGINE_RESULT_OK) {
            rgba.swap(movie_pixels_); width = frame.width; height = frame.height;
            movie_serial_ = state.frame_serial; ++serial;
        }
        return true;
    }
    void Exit() {
        exit_ = true;
        if (host_.platform_request) host_.platform_request(host_.user_data, "runtime_end", "");
    }

    engine_runtime_host_v1_t host_;
    fs::path root_;
    std::string ticket_;
    std::unique_ptr<SaveBank> saves_;
    nnn::snapshot::Bytes previous_progress_;
    bool progress_loaded_ = false;
    SessionOptions options_;
    std::unique_ptr<GameSession> game_;
    std::unique_ptr<Presentation> presentation_;
    std::unique_ptr<SettingsPage> settings_;
    int remembered_settings_page_ = 1;
    SDL_AudioDeviceID audio_ = 0;
    bool audio_initialized_ = false, paused_ = false, title_ = false, exit_ = false, dirty_ = true;
    Menu menu_ = Menu::None;
    int selection_ = 0, pressed_ = -1, slot_page_ = 0, overwrite_ = 0;
    std::string notice_;
    std::vector<Button> buttons_, title_buttons_;
    std::vector<std::string> gallery_;
    int gallery_index_ = 0;
    std::shared_ptr<const emberfall::render::Texture> gallery_picture_;
    InputState input_;
    engine_media_handle_t movie_ = nullptr;
    uint64_t movie_serial_ = UINT64_MAX;
    bool movie_skippable_ = true;
    std::vector<uint8_t> movie_pixels_;
};

template<class F>
engine_result_t Call(void *p, F fn) {
    if (!p) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto &runtime = *static_cast<Runtime *>(p);
    try { fn(runtime); return ENGINE_RESULT_OK; }
    catch (const std::exception &e) { runtime.error = e.what(); return ENGINE_RESULT_IO_ERROR; }
}

engine_result_t Copy(const std::string &text, char *out, uint32_t size, uint32_t *written = nullptr) {
    if (written) *written = uint32_t(text.size());
    if (!out || size <= text.size()) return ENGINE_RESULT_INVALID_ARGUMENT;
    std::memcpy(out, text.c_str(), text.size()+1);
    return ENGINE_RESULT_OK;
}

engine_runtime_provider_v1_t Provider() {
    engine_runtime_provider_v1_t v{};
    v.struct_size = sizeof(v); v.api_version = ENGINE_RUNTIME_PROVIDER_API_VERSION;
    v.runtime_id_utf8 = "systemnnn"; v.display_name_utf8 = "SystemNNN / Emberfall"; v.priority = 90;
    v.probe = [](void *, const char *path) -> int32_t {
        try {
            if (!path || !*path) return 0;
            auto root = fs::u8path(path);
            if (fs::is_regular_file(root)) root = root.parent_path();
            return nnn::resource::find_file(nnn::resource::find_directory(root, "spt"), "sys.spt").empty() ? 0 : 95;
        } catch (...) { return 0; }
    };
    v.create = [](void *, const engine_runtime_host_v1_t *host, const engine_create_desc_t *, void **out) {
        if (!host || !out) return ENGINE_RESULT_INVALID_ARGUMENT;
        *out = new(std::nothrow) Runtime(*host);
        return *out ? ENGINE_RESULT_OK : ENGINE_RESULT_INTERNAL_ERROR;
    };
    v.destroy = [](void *p) { delete static_cast<Runtime *>(p); };
    v.open_game = [](void *p, const char *root, const char *entry) {
        if (!root || !*root) return ENGINE_RESULT_INVALID_ARGUMENT;
        return Call(p, [&](Runtime &r){ r.Open(root, entry); });
    };
    v.tick = [](void *p, uint32_t ms) { return Call(p, [&](Runtime &r){ r.Tick(ms); }); };
    v.pause = [](void *p) { return Call(p, [](Runtime &r){ r.Pause(true); }); };
    v.resume = [](void *p) { return Call(p, [](Runtime &r){ r.Pause(false); }); };
    v.set_option = [](void *p, const engine_option_t *option) {
        if (!p || !option || !option->key_utf8 || !option->value_utf8) return ENGINE_RESULT_INVALID_ARGUMENT;
#ifdef __ANDROID__
        if (std::string_view(option->key_utf8) == "systemnnn.android_player") {
            static_cast<Runtime *>(p)->android_player = std::string_view(option->value_utf8) == "1";
            return ENGINE_RESULT_OK;
        }
#endif
        if (std::string_view(option->key_utf8) != "default_font") return ENGINE_RESULT_NOT_SUPPORTED;
        return Call(p, [&](Runtime &r){ r.font = option->value_utf8; });
    };
    v.set_surface_size = [](void *p, uint32_t w, uint32_t h){ return p && w && h ? ENGINE_RESULT_OK : ENGINE_RESULT_INVALID_ARGUMENT; };
    v.send_input = [](void *p, const engine_input_event_t *e) {
        if (!e || e->struct_size < sizeof(*e) || !std::isfinite(e->x) || !std::isfinite(e->y)) return ENGINE_RESULT_INVALID_ARGUMENT;
        return Call(p, [&](Runtime &r){ r.Input(*e); });
    };
    v.get_frame_desc = [](void *p, engine_frame_desc_t *out) {
        if (!p || !out || out->struct_size < sizeof(*out)) return ENGINE_RESULT_INVALID_ARGUMENT;
        auto &r = *static_cast<Runtime *>(p);
        if (!r.serial) return ENGINE_RESULT_INVALID_STATE;
        out->width = r.width; out->height = r.height; out->stride_bytes = r.width*4;
        out->frame_serial = r.serial; out->pixel_format = ENGINE_PIXEL_FORMAT_RGBA8888;
        return ENGINE_RESULT_OK;
    };
    v.read_frame_rgba = [](void *p, void *out, size_t size) {
        if (!p || !out) return ENGINE_RESULT_INVALID_ARGUMENT;
        auto &r = *static_cast<Runtime *>(p);
        if (!r.serial || size < r.rgba.size()) return ENGINE_RESULT_INVALID_ARGUMENT;
        std::memcpy(out, r.rgba.data(), r.rgba.size()); r.delivered = r.serial;
        return ENGINE_RESULT_OK;
    };
    v.get_frame_rendered_flag = [](void *p, uint32_t *out) {
        if (!p || !out) return ENGINE_RESULT_INVALID_ARGUMENT;
        auto &r = *static_cast<Runtime *>(p); *out = r.serial != r.delivered; return ENGINE_RESULT_OK;
    };
    v.submit_platform_response = [](void *p, const char *op, const char *ticket) {
        if (!p || !op || !ticket) return ENGINE_RESULT_INVALID_ARGUMENT;
        return static_cast<Runtime *>(p)->PlayerClosed(op, ticket);
    };
    v.get_renderer_info = [](void *, char *out, uint32_t size){ return Copy("backend=systemnnn native-software frame=rgba", out, size); };
    v.get_plugin_debug_info = [](void *p, char *out, uint32_t size, uint32_t *written) {
        if (!p) return ENGINE_RESULT_INVALID_ARGUMENT;
        return Copy(static_cast<Runtime *>(p)->Info(), out, size, written);
    };
    v.get_last_error = [](void *p) -> const char * { return p ? static_cast<Runtime *>(p)->error.c_str() : "No SystemNNN session"; };
    return v;
}
} // namespace

void RegisterProvider() {
    static const auto provider = Provider();
    engine_register_runtime_provider(&provider);
}
} // namespace aether::systemnnn
