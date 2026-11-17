#include "systemnnn_runtime.h"
#include "systemnnn_audio.h"
#include "systemnnn_presenter.h"
#include "systemnnn_text.h"
#include "systemnnn_progress.h"
#include "systemnnn_movie.h"
#include "systemnnn_startup.h"
#include "systemnnn_native_panel.h"
#include "emberfall/story_compositor.hpp"
#include "nnn/resource_path.hpp"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <unordered_map>
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

namespace aether::systemnnn {
namespace fs = std::filesystem;
using namespace emberfall;
using scene::GameSession;
using scene::Wait;
using Json = nlohmann::json;

static std::vector<nnn::Byte> read_file(const fs::path& path, std::size_t limit=128U*1024U*1024U) {
    const auto size=fs::file_size(path);
    if(size>limit) throw std::runtime_error("File exceeds size limit: "+path.u8string());
    std::ifstream in(path,std::ios::binary);
    std::vector<nnn::Byte> data(static_cast<std::size_t>(size));
    if(!in || (size && !in.read(reinterpret_cast<char*>(data.data()),static_cast<std::streamsize>(size))))
        throw std::runtime_error("Cannot read "+path.u8string());
    return data;
}
static void write_file(const fs::path& path,const std::vector<nnn::Byte>& data) {
    fs::create_directories(path.parent_path());
    auto temporary=path; temporary+=".tmp";
    { std::ofstream out(temporary,std::ios::binary|std::ios::trunc);
      if(!out || !out.write(reinterpret_cast<const char*>(data.data()),static_cast<std::streamsize>(data.size())) || !out.flush())
          throw std::runtime_error("Cannot write "+temporary.u8string()); }
    // Keep the preceding slot until the replacement has been written completely.
#if defined(_WIN32)
    if(!MoveFileExW(temporary.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))
        throw std::runtime_error("Cannot commit save: Windows error "+std::to_string(GetLastError()));
#else
    const int descriptor=::open(temporary.c_str(),O_RDONLY);
    if(descriptor<0)throw std::runtime_error("Cannot open temporary save for flush");
    const int sync_result=::fsync(descriptor);::close(descriptor);
    if(sync_result!=0)throw std::runtime_error("Cannot flush temporary save");
    std::error_code ec;fs::rename(temporary,path,ec);
    if(ec)throw std::runtime_error("Cannot commit save: "+ec.message());
    const int directory=::open(path.parent_path().c_str(),O_RDONLY);
    if(directory>=0){::fsync(directory);::close(directory);}
#endif
}
static std::string utf8(const std::u32string& input) {
    std::string output;for(uint32_t c:input){
        if(c<0x80)output.push_back(static_cast<char>(c));
        else if(c<0x800){output.push_back(static_cast<char>(0xc0|(c>>6)));output.push_back(static_cast<char>(0x80|(c&63)));}
        else if(c<0x10000){output.push_back(static_cast<char>(0xe0|(c>>12)));output.push_back(static_cast<char>(0x80|((c>>6)&63)));output.push_back(static_cast<char>(0x80|(c&63)));}
        else {output.push_back(static_cast<char>(0xf0|(c>>18)));output.push_back(static_cast<char>(0x80|((c>>12)&63)));output.push_back(static_cast<char>(0x80|((c>>6)&63)));output.push_back(static_cast<char>(0x80|(c&63)));}
    }return output;
}
static engine_result_t copy_string(const std::string& value,char* buffer,uint32_t size,uint32_t* written=nullptr) {
    if(written) *written=static_cast<uint32_t>(value.size()+1);
    if(!buffer || size<=value.size()) return ENGINE_RESULT_INVALID_ARGUMENT;
    std::memcpy(buffer,value.c_str(),value.size()+1); return ENGINE_RESULT_OK;
}

struct Frame {
    engine_frame_desc_t desc{};
    std::vector<uint8_t> rgba;
};
struct Runtime {
    engine_runtime_host_v1_t host{};
    std::mutex game_mutex;
    fs::path root,writable,cache;
    scene::SessionOptions session_options;
    std::unique_ptr<GameSession> game;
    std::unique_ptr<GameSession> preview;
    TextRenderer text;
    std::unique_ptr<Presenter> presenter;
    scene::StoryCompositor compositor;
    AudioOutput audio;
    MoviePlayer movie;
    std::unique_ptr<StartupSequence> startup_sequence;
    bool movie_from_startup=false,movie_skippable=true;
    uint64_t movie_request=0;
    std::shared_ptr<const Frame> frame,described_frame;
    std::unordered_map<std::string,std::string> options;
    std::string error,overlay="title",previous_overlay;
    uint64_t serial=0,line_sequence=UINT64_MAX;
    uint32_t surface_width=0,surface_height=0;
    scene::InputState input;
    bool paused=false,audio_enabled=true,auto_mode=false,closed=false;
    bool text_request=false,native_menu_open=false;
    unsigned selected=1;
    explicit Runtime(const engine_runtime_host_v1_t* h,const engine_create_desc_t* desc) {
        if(h) std::memcpy(&host,h,std::min<std::size_t>(sizeof(host),h->struct_size));
        if(desc->writable_path_utf8) writable=fs::u8path(desc->writable_path_utf8);
        if(desc->cache_path_utf8) cache=fs::u8path(desc->cache_path_utf8);
    }
    ~Runtime() { audio.stop();if(game) {try {persist();}catch(...) {}} }
    void persist() {
        if(!game)return;
        for(const auto& warning:save_progress(*game,root,writable))log(ENGINE_RUNTIME_LOG_WARNING,warning);
    }
    void log(uint32_t level,const std::string& message) {
        if(host.log) host.log(host.user_data,level,"systemnnn",message.c_str());
    }
    void request(const char* operation,const std::string& argument) {
        if(host.platform_request) host.platform_request(host.user_data,operation,argument.c_str());
    }
    GameSession* audio_game() { return game.get(); }
    fs::path slot(unsigned number) const {
        if(number>999) throw std::invalid_argument("Invalid save slot");
        auto base=writable.empty()?root/"sav":writable/"systemnnn";
        return base/("slot-"+std::to_string(number)+".sav");
    }
    scene::SessionOptions fresh_options(bool fork=false) {
        auto result=session_options;
        if(game) { result.runtime=fork?game->runtime()->fork():game->runtime(); result.save_layout=game->runtime_ref().save_layout; }
        return result;
    }
    void begin_audio() {
        if(!audio_enabled) return;
        if(!audio.start([this](int16_t* samples,std::size_t frames) {
            std::lock_guard<std::mutex> guard(game_mutex);
            if(movie.active() && !paused) movie.pull(samples,frames);
            else if(auto* owner=audio_game();owner && !paused) owner->audio().pull(samples,frames);
            else std::fill_n(samples,frames*2,0);
        },session_options.audio.sample_rate)) log(ENGINE_RUNTIME_LOG_WARNING,"Audio device unavailable: "+audio.error());
    }
    void close_overlay() {
        overlay=preview?"title":"";input={};
        if(native_menu_open){native_menu_open=false;if(game->resume_native_panel()){game->audio().restart_loop_script_audio();game->reset_frame_pacing();}}
    }
    void title() {
        native_menu_open=false;
        persist();
        overlay="title"; auto_mode=false; input={}; preview.reset();
        auto opts=fresh_options();
        preview=GameSession::create_ui_preview(root,opts);
        if(!presenter->title_script().empty()) {
            preview->reset_ui_background(presenter->title_script(),4,game->runtime());
            preview->step_ui_background({},presenter->title_script_loop());
        }
        const auto& config=presenter->title_config();
        game->audio().play_menu_music(config.number("bgmNumber",1),config.number("bgmLoop",0),
            config.number("bgmVolume",0),config.number("bgmFadeInTime",-1),config.number("bgmRestartFlag",1)!=0);
        compositor.reset_present_state();
    }
    void start_story() {
        auto candidate=std::make_unique<GameSession>(root,fresh_options());
        candidate->audio().inherit_music(game->audio());
        game=std::move(candidate); native_menu_open=false;preview.reset(); overlay.clear(); input={}; line_sequence=UINT64_MAX;
        game->sync_runtime_names(); compositor.reset_present_state();
        input.play_movies=true;game->step_frame(0,input); update_line();
    }
    void refresh_slots() {
        std::vector<SaveSlotInfo> slots;
        const auto directory=slot(1).parent_path();
        if(fs::is_directory(directory))for(const auto& item:fs::directory_iterator(directory)) {
            const auto name=item.path().filename().u8string();
            if(name.rfind("slot-",0)!=0 || name.size()<10 || name.substr(name.size()-4)!=".sav")continue;
            try {
                const auto digits=name.substr(5,name.size()-9);if(digits.empty() || digits.find_first_not_of("0123456789")!=std::string::npos)continue;
                const int number=std::stoi(digits);if(number<1 || number>999)continue;
                SaveSlotInfo info;info.slot=number;
                const auto saved=GameSession::inspect_pc_save(read_file(item.path(),16U*1024U*1024U),512U*512U);
                info.occupied=true;info.title=utf8(text.decode(saved.summary));
                const auto& t=saved.time;info.timestamp=std::to_string(t[0])+"/"+std::to_string(t[1])+"/"+std::to_string(t[2])+" "+std::to_string(t[3])+":"+std::to_string(t[4]);
                if(saved.width>0 && saved.height>0 && saved.pixels.size()==static_cast<std::size_t>(saved.width)*saved.height) {
                    auto thumbnail=std::make_shared<render::Texture>();thumbnail->canvas_width=saved.width;thumbnail->canvas_height=saved.height;
                    thumbnail->content={0,0,saved.width,saved.height};thumbnail->pixels.width=saved.width;thumbnail->pixels.height=saved.height;thumbnail->pixels.rgba.reserve(saved.pixels.size()*4);
                    for(auto color:saved.pixels){thumbnail->pixels.rgba.push_back(static_cast<uint8_t>(color>>16));thumbnail->pixels.rgba.push_back(static_cast<uint8_t>(color>>8));thumbnail->pixels.rgba.push_back(static_cast<uint8_t>(color));thumbnail->pixels.rgba.push_back(255);}
                    info.thumbnail=std::move(thumbnail);
                }
                slots.push_back(std::move(info));
            } catch(const std::exception& e){log(ENGINE_RUNTIME_LOG_WARNING,"Unreadable save preview "+name+": "+e.what());}
        }
        presenter->set_save_slots(std::move(slots));
    }
    void save(unsigned number) {
        if(!game || (!overlay.empty() && overlay!="save" && overlay!="menu")) throw std::runtime_error("No active story to save");
        if(game->state().wait==Wait::NativePanel && !game->native_panel_can_save())throw std::runtime_error("Native panel cannot save during this interaction");
        write_file(slot(number),game->export_presented_pc_save());
        persist();
        close_overlay(); log(ENGINE_RUNTIME_LOG_INFO,"Saved slot "+std::to_string(number));
    }
    void load(unsigned number) {
        auto candidate=std::make_unique<GameSession>(root,fresh_options(true));
        candidate->load_pc_save_candidate(read_file(slot(number)),preview?nullptr:game.get());
        // The audio callback takes game_mutex, so replacing ownership here is serialized.
        game=std::move(candidate); native_menu_open=false;preview.reset(); overlay.clear(); input={}; line_sequence=UINT64_MAX;
        game->set_chart_storage(writable.empty()?root/"sav":writable/"systemnnn");
        compositor.reset_present_state(); update_line();
    }
    void update_line() {
        const auto& state=game->state();
        if(state.wait==Wait::Dialogue && state.dialogue.sequence!=line_sequence) {
            line_sequence=state.dialogue.sequence;
            const auto body=TextRenderer::plain_dialogue(text.decode(state.dialogue.display_bytes));
            game->begin_player_line(game->audio().state().voices[0].active,game->audio().voice_duration_ms(0));
            game->set_text_length(static_cast<uint32_t>(body.size()),static_cast<uint32_t>(body.size()));
        }
    }
    void action(const std::string& action) {
        if(action.empty()) return;
        if(startup_sequence && !startup_sequence->finished()){input.advance=true;return;}
        if(game && !preview && overlay.empty() && game->state().wait==Wait::NativePanel && native_panel::action(*game,action,input.mouse_x,input.mouse_y))return;
        if(action=="start") start_story();
        else if(action=="title") title();
        else if(action=="exit") { closed=true; request("runtime_end",""); }
        else if(action=="back") {
            if(!overlay.empty()) { close_overlay(); }
            else if(game->state().modal) game->act_modal(game->state().modal->request,0,0);
            else overlay="menu";
        } else if(action=="save" || action=="load" || action=="settings" || action=="backlog") {
            if(action=="save" && preview) return;
            overlay=action; presenter->set_page(0);if(action=="save" || action=="load")refresh_slots();
        } else if(action=="menu") { if(game->options_enabled()) overlay="menu"; }
        else if(action=="auto") { auto_mode=!auto_mode; overlay.clear(); }
        else if(action=="skip") { game->set_skip_active(!game->skip_active()); overlay.clear(); }
        else if(action=="extras") { preview.reset(); overlay.clear(); game->open_modal(nnn::RuntimeMode::Omake,nnn::RuntimeMode::Title,true); }
        else if(action=="next_page" || action=="page:next") presenter->set_page(presenter->page()+1);
        else if(action=="previous_page" || action=="page:prev") presenter->set_page(std::max(0,presenter->page()-1));
        else if(action.rfind("choice:",0)==0) input.choice=static_cast<unsigned>(std::stoul(action.substr(7)));
        else if(action.rfind("place:",0)==0) input.choice=static_cast<unsigned>(std::stoul(action.substr(6)));
        else if(action.rfind("param:",0)==0) {
            const auto separator=action.find(':',6);
            if(separator==std::string::npos)throw std::invalid_argument("Invalid parameter action");
            if(!game->set_system_parameter(static_cast<nnn::Word>(std::stoul(action.substr(6,separator-6))),std::stoi(action.substr(separator+1))))
                throw std::invalid_argument("Unknown SystemNNN parameter");
            game->apply_runtime_parameters();
        }
        else if(action.rfind("modal:action:",0)==0 && game->state().modal) {
            const auto separator=action.find(':',13);
            if(separator==std::string::npos)throw std::invalid_argument("Invalid modal action");
            const auto request=game->state().modal->request;
            const int result=game->act_modal(request,std::stoi(action.substr(13,separator-13)),std::stoi(action.substr(separator+1)));
            if(result==4)game->act_modal(request,8,0);else if(result==2)title();
        }
        else if(action.rfind("modal:page:",0)==0 && game->state().modal) {
            game->act_modal(game->state().modal->request,2,std::stoi(action.substr(11)));
        }
        else if(action.rfind("modal:",0)==0 && game->state().modal) {
            const auto request_id=game->state().modal->request;
            int result=game->act_modal(request_id,1,std::stoi(action.substr(6)));
            if(result==4) game->act_modal(request_id,8,0);
            else if(result==2) title();
        } else if(action.rfind("slot:",0)==0) {
            const auto number=static_cast<unsigned>(std::stoul(action.substr(5)));
            if(overlay=="save") save(number); else load(number);
        } else if(action=="quicksave") save(0);
        else if(action=="quickload") load(0);
    }
    void publish(const render::Surface& surface) {
        if(!surface.width || !surface.height || surface.rgb.size()!=static_cast<std::size_t>(surface.width)*surface.height*3)
            throw std::runtime_error("Invalid SystemNNN frame");
        auto next=std::make_shared<Frame>();
        next->desc.struct_size=sizeof(engine_frame_desc_t);
        next->desc.width=surface.width;next->desc.height=surface.height;next->desc.stride_bytes=surface.width*4;
        next->desc.pixel_format=ENGINE_PIXEL_FORMAT_RGBA8888;next->desc.frame_serial=++serial;
        next->rgba.resize(static_cast<std::size_t>(surface.width)*surface.height*4);
        for(std::size_t source=0,dest=0;source<surface.rgb.size();source+=3,dest+=4) {
            next->rgba[dest]=surface.rgb[source];next->rgba[dest+1]=surface.rgb[source+1];next->rgba[dest+2]=surface.rgb[source+2];next->rgba[dest+3]=255;
        }
        frame=std::move(next);
    }
    void present() {
        if(movie.active()) {if(const auto* image=movie.frame())publish(*image);return;}
        if(startup_sequence && !startup_sequence->finished() && !startup_sequence->awaiting_title()) {
            if(const auto* image=startup_sequence->frame())publish(*image);return;
        }
        auto& owner=preview?*preview:*game;
        auto plane=presenter->render(owner,overlay);
        if(preview || !overlay.empty()) {
            owner.clear_message_plane();
            auto composed=owner.surface();
            for(std::size_t px=0,rgb=0;px<plane->rgba.size();px+=4,rgb+=3) {
                const unsigned inverse=255U-plane->rgba[px+3];
                for(std::size_t c=0;c<3;++c)composed.rgb[rgb+c]=static_cast<render::Byte>(std::min(255U,unsigned(plane->rgba[px+c])+(unsigned(composed.rgb[rgb+c])*inverse+127U)/255U));
            }
            publish(composed);if(preview)owner.after_present();return;
        }
        owner.set_message_plane(plane);
        const auto key=owner.expected_plane_key();
        auto complete_key=key; complete_key[5]|=1<<17;
        compositor.mailbox()->set_attached(true);
        compositor.mailbox()->push(plane->rgba.data(),plane->stride,plane->width,plane->height,complete_key,
            plane->show_backdrop,plane->floating_rgba.empty()?nullptr:plane->floating_rgba.data(),plane->stride);
        compositor.present(owner,true,!preview && overlay.empty(),[this](const render::Surface& surface){publish(surface);return true;});
    }
    void tick(uint32_t ms) {
        if(!game || paused || closed) return;
        if(movie.active()) {
            movie.tick(ms);
            if(!movie.error().empty())throw std::runtime_error(movie.error());
            if(movie.ended() || (input.advance && movie_skippable)) {
                movie.close();input.advance=false;
                if(movie_from_startup && startup_sequence)startup_sequence->finish_movie();
                else {game->step_frame(scene::FrameTiming{0,0},input);game->reset_frame_pacing();}
            } else {input.advance=false;present();return;}
        }
        if(startup_sequence && !startup_sequence->finished()) {
            startup_sequence->tick(ms,input.advance);input={};
            if(startup_sequence->awaiting_movie()) {
                const auto request=*startup_sequence->movie_request();
                fs::path path;
                if(request.movie_number)path=resolve_movie(root,request.movie_number);
                else {
                    const auto directory=nnn::resource::find_directory(root,"movie");
                    path=nnn::resource::find_file(directory,request.filename,session_options.filename_encoder);
                    if(path.empty())for(const char* suffix:{".wmv",".mpg",".mpeg",".avi",".mp4"}) {
                        path=nnn::resource::find_file(directory,request.filename+suffix,session_options.filename_encoder);if(!path.empty())break;
                    }
                }
                std::string reason;if(!movie.open(path,reason))throw std::runtime_error(reason);
                movie_from_startup=true;movie_skippable=request.skippable;
            }
            if(startup_sequence->awaiting_title()) {
                title();present();
                render::Surface composed;composed.width=frame->desc.width;composed.height=frame->desc.height;
                composed.rgb.resize(static_cast<std::size_t>(composed.width)*composed.height*3);
                for(std::size_t in=0,out=0;out<composed.rgb.size();in+=4,out+=3)std::copy_n(frame->rgba.data()+in,3,composed.rgb.data()+out);
                startup_sequence->begin_title(composed);
            }
            if(!startup_sequence->finished()){present();return;}
            startup_sequence.reset();
        }
        if(preview) {
            if(!presenter->title_script().empty()) preview->tick_ui_background(input,presenter->title_script_loop(),ms);
        } else if(overlay.empty()) {
            const auto& state=game->state();
            if(state.wait==Wait::Error) throw std::runtime_error(state.error);
            if(state.wait==Wait::Ended) { title(); present(); return; }
            if(state.wait==Wait::Movie && state.movie) {
                std::string reason;
                if(!movie.open(resolve_movie(root,state.movie),reason))throw std::runtime_error(reason);
                movie_request=state.movie;movie_from_startup=false;movie_skippable=true;
                input={};present();return;
            }
            if(state.wait==Wait::Modal && state.modal && !text_request &&
               (state.modal->mode==nnn::RuntimeMode::NameInput || state.modal->mode==nnn::RuntimeMode::KanjiInput)) {
                text_request=true;
                const auto& modal=*state.modal;
                Json items=Json::array();const auto count=std::clamp<std::size_t>(modal.byte_limits.size(),1,8);
                for(std::size_t i=0;i<count;++i){
                    items.push_back({{"kind","label"},{"rect",{12,12+static_cast<int>(i)*76,410,24}},{"text",count==1?"Name":"Name "+std::to_string(i+1)}});
                    items.push_back({{"kind","multiline"},{"id","field"+std::to_string(i)},{"rect",{12,38+static_cast<int>(i)*76,410,46}},{"value",i<modal.text.size()?utf8(text.decode(modal.text[i])):""}});
                }
                const int height=100+static_cast<int>(count)*76;
                items.push_back({{"kind","button"},{"id","1"},{"rect",{12,height-48,198,36}},{"text","OK"}});
                items.push_back({{"kind","button"},{"id","2"},{"rect",{224,height-48,198,36}},{"text","Cancel"}});
                request("runtime_form",Json{{"title","SystemNNN"},{"width",434},{"height",height},{"items",items}}.dump());
            }
            if(state.wait==Wait::Dialogue && (game->skip_effective() || (auto_mode && game->auto_ready(ms,true)))) input.advance=true;
            // Only a fully composed and acknowledged message may advance the VM.
            if(input.advance && !scene::scene_plane_key_matches(compositor.presented_plane_key(),game->expected_plane_key())) input.advance=false;
            if(input.advance) input.advance=game->request_advance();
            input.play_movies=true;
            if(!compositor.waiting_for_draw(*game)) game->step_frame(scene::FrameTiming{ms,game->pace(ms)},input);
            update_line();
            if(const auto view=native_panel::menu_overlay(game->take_native_panel_menu());!view.empty()){
                native_menu_open=true;overlay=std::string(view);input={};auto_mode=false;game->set_skip_active(false);
                game->audio().suspend_script_audio();presenter->set_page(0);if(overlay=="save" || overlay=="load")refresh_slots();
            }
            if(game->take_system_save_request())persist();
        }
        input.advance=false;input.choice=0;
        present();
    }
};

template<class Function> static engine_result_t guarded(void* opaque,Function fn) {
    if(!opaque) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto& self=*static_cast<Runtime*>(opaque);
    try { std::lock_guard<std::mutex> lock(self.game_mutex);fn(self);self.error.clear();return ENGINE_RESULT_OK; }
    catch(const std::exception& e) { self.error=e.what();self.log(ENGINE_RUNTIME_LOG_ERROR,self.error);return ENGINE_RESULT_IO_ERROR; }
    catch(...) { self.error="Unhandled SystemNNN exception";return ENGINE_RESULT_INTERNAL_ERROR; }
}
static int32_t probe(void*,const char* root) {
    if(!root || !*root) return 0;
    try { const auto spt=nnn::resource::find_directory(fs::u8path(root),"spt");
        const auto sys=nnn::resource::find_file(spt,"sys.spt");
        return !sys.empty() && fs::is_regular_file(sys)?100:0;
    } catch(...) {return 0;}
}
static engine_result_t create(void*,const engine_runtime_host_v1_t* host,const engine_create_desc_t* desc,void** out) {
    if(!desc || !out || desc->struct_size<sizeof(engine_create_desc_t)) return ENGINE_RESULT_INVALID_ARGUMENT;
    *out=nullptr;
    try {*out=new Runtime(host,desc);return ENGINE_RESULT_OK;}catch(...){return ENGINE_RESULT_INTERNAL_ERROR;}
}
static engine_result_t open(void* opaque,const char* root,const char* startup) {
    if(!opaque || !root || !*root) return ENGINE_RESULT_INVALID_ARGUMENT;
    auto& self=*static_cast<Runtime*>(opaque);
    self.audio.stop();
    const auto result=guarded(opaque,[&](Runtime& r) {
        r.persist();r.movie.close();r.startup_sequence.reset();r.root=fs::u8path(root);r.game.reset();r.preview.reset();r.closed=false;
        r.text.load_game_codec(r.root);
        std::vector<fs::path> fonts;
        if(auto it=r.options.find("systemnnn.font");it!=r.options.end()) fonts.push_back(fs::u8path(it->second));
        if(auto it=r.options.find("default_font");it!=r.options.end()) fonts.push_back(fs::u8path(it->second));
        if(auto it=r.options.find("font_dir");it!=r.options.end()) fonts.push_back(fs::u8path(it->second)/"aetherkiri-runtime-cjk.otf");
        fonts.push_back(r.root/"aetherkiri-runtime-cjk.otf");
#ifdef AETHERKIRI_SYSTEMNNN_FONT
        fonts.emplace_back(fs::u8path(AETHERKIRI_SYSTEMNNN_FONT));
#endif
        fonts.emplace_back("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc");
        fonts.emplace_back("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf");
        bool loaded=false;for(const auto& font:fonts) if(r.text.load_font(font)){loaded=true;break;}
        if(!loaded) throw std::runtime_error("SystemNNN needs a font: set systemnnn.font to a readable CJK font");
        r.presenter=std::make_unique<Presenter>(r.root,r.text);
        r.session_options={};r.session_options.queue_audio_events=false;r.session_options.audio.sample_rate=44100;
        r.session_options.filename_encoder=[&r](const std::string& value)->std::optional<std::string> {
            try{return r.text.encode(r.text.decode_utf8(value),4096);}catch(...){return std::nullopt;}
        };
        if(startup && *startup) {r.session_options.entry=r.text.encode(r.text.decode_utf8(startup),4096);r.overlay.clear();}
        r.game=std::make_unique<GameSession>(r.root,r.session_options);
        r.game->set_chart_storage(r.writable.empty()?r.root/"sav":r.writable/"systemnnn");
        for(const auto& warning:load_progress(*r.game,r.root,r.writable))r.log(ENGINE_RUNTIME_LOG_WARNING,warning);
        if((startup && *startup) || r.options["systemnnn.start_in_story"]=="1") r.start_story();
        else {
            r.title();r.startup_sequence=std::make_unique<StartupSequence>(r.root);
            r.startup_sequence->start(*r.game,r.session_options,r.preview.get());r.tick(0);
        }
        r.present();
    });
    if(result==ENGINE_RESULT_OK) self.begin_audio();
    return result;
}
static engine_result_t tick(void* opaque,uint32_t ms){return guarded(opaque,[&](Runtime& r){r.tick(ms);});}
static engine_result_t pause(void* opaque){return guarded(opaque,[](Runtime& r){r.paused=true;r.input={};if(r.game)r.game->set_ctrl_skip(false);r.audio.pause(true);r.movie.pause(true);r.persist();});}
static engine_result_t resume(void* opaque){return guarded(opaque,[](Runtime& r){r.paused=false;r.audio.pause(false);r.movie.pause(false);if(r.game)r.game->reset_frame_pacing();});}
static engine_result_t option(void* opaque,const engine_option_t* option) {
    if(!option || !option->key_utf8 || !option->value_utf8) return ENGINE_RESULT_INVALID_ARGUMENT;
    return guarded(opaque,[&](Runtime& r){
        const std::string key=option->key_utf8,value=option->value_utf8;
        r.options[key]=value;
        if(key=="systemnnn.audio") r.audio_enabled=value!="0";
        else if(key=="systemnnn.action") {r.action(value);if(r.game)r.present();}
        else if(key=="systemnnn.save_slot") r.save(static_cast<unsigned>(std::stoul(value)));
        else if(key=="systemnnn.load_slot") {r.load(static_cast<unsigned>(std::stoul(value)));r.present();}
        else if(key=="systemnnn.auto") r.auto_mode=value=="1";
        else if(key=="systemnnn.skip" && r.game)r.game->set_skip_active(value=="1");
        else if(key.rfind("systemnnn.parameter.",0)==0 && r.game) {
            if(!r.game->set_system_parameter(static_cast<nnn::Word>(std::stoul(key.substr(20))),std::stoi(value)))
                throw std::invalid_argument("Unknown SystemNNN parameter");
        }
    });
}
static engine_result_t surface(void* opaque,uint32_t width,uint32_t height) {
    if(!width || !height || width>32768 || height>32768) return ENGINE_RESULT_INVALID_ARGUMENT;
    return guarded(opaque,[&](Runtime& r){r.surface_width=width;r.surface_height=height;});
}
static engine_result_t describe(void* opaque,engine_frame_desc_t* out) {
    if(!out || out->struct_size<sizeof(engine_frame_desc_t))return ENGINE_RESULT_INVALID_ARGUMENT;
    if(!opaque)return ENGINE_RESULT_INVALID_ARGUMENT;
    auto& r=*static_cast<Runtime*>(opaque);std::lock_guard<std::mutex> guard(r.game_mutex);
    if(!r.frame)return ENGINE_RESULT_INVALID_STATE;
    r.described_frame=r.frame;*out=r.frame->desc;return ENGINE_RESULT_OK;
}
static engine_result_t read_frame(void* opaque,void* pixels,size_t size) {
    if(!opaque || !pixels)return ENGINE_RESULT_INVALID_ARGUMENT;
    auto& r=*static_cast<Runtime*>(opaque);std::lock_guard<std::mutex> guard(r.game_mutex);
    auto snapshot=r.described_frame?r.described_frame:r.frame;
    if(!snapshot)return ENGINE_RESULT_INVALID_STATE;
    if(size<snapshot->rgba.size())return ENGINE_RESULT_INVALID_ARGUMENT;
    std::memcpy(pixels,snapshot->rgba.data(),snapshot->rgba.size());return ENGINE_RESULT_OK;
}
static engine_result_t send_input(void* opaque,const engine_input_event_t* event) {
    if(!event || event->struct_size<sizeof(engine_input_event_t))return ENGINE_RESULT_INVALID_ARGUMENT;
    return guarded(opaque,[&](Runtime& r){
        if(!r.game || !r.frame || r.paused)return;
        // Godot maps aspect-fit viewport coordinates into native frame pixels.
        const double sx=1,sy=1;
        if(!std::isfinite(event->x) || !std::isfinite(event->y))return;
        r.input.mouse_x=static_cast<int>(std::clamp(event->x*sx,-32768.0,32768.0));
        r.input.mouse_y=static_cast<int>(std::clamp(event->y*sy,-32768.0,32768.0));
        if(!r.preview && r.overlay.empty() && r.game->state().wait==Wait::NativePanel) {
            using Pointer=native_panel::Pointer;const int x=r.input.mouse_x,y=r.input.mouse_y;
            if(event->type==ENGINE_INPUT_EVENT_POINTER_MOVE)native_panel::pointer(*r.game,Pointer::Move,event->button,x,y);
            else if(event->type==ENGINE_INPUT_EVENT_POINTER_DOWN)native_panel::pointer(*r.game,Pointer::Down,event->button,x,y);
            else if(event->type==ENGINE_INPUT_EVENT_POINTER_UP)native_panel::pointer(*r.game,(event->modifiers&ENGINE_INPUT_MODIFIER_POINTER_CANCEL)?Pointer::Cancel:Pointer::Up,event->button,x,y);
            else if(event->type==ENGINE_INPUT_EVENT_BACK)native_panel::back(*r.game,x,y);
            else if(event->type==ENGINE_INPUT_EVENT_KEY_DOWN)native_panel::key_down(*r.game,event->key_code,x,y);
            r.input.advance=false;r.input.held=false;r.input.choice=0;return;
        }
        if(event->type==ENGINE_INPUT_EVENT_POINTER_DOWN)r.input.held=true;
        if(event->type==ENGINE_INPUT_EVENT_POINTER_UP) {
            r.input.held=false;
            if(event->modifiers & ENGINE_INPUT_MODIFIER_POINTER_CANCEL)return;
            if(event->button==1){r.action("back");return;}
            auto action=r.presenter->hit(r.input.mouse_x,r.input.mouse_y);
            if(!action.empty())r.action(action);
            else if(r.game->state().wait==Wait::NativePanel)r.game->native_panel_input(r.input.mouse_x,r.input.mouse_y,true,false);
            else if(r.overlay.empty())r.input.advance=true;
        } else if(event->type==ENGINE_INPUT_EVENT_BACK)r.action("back");
        else if(event->type==ENGINE_INPUT_EVENT_KEY_DOWN) {
            switch(event->key_code) {
            case 0x1b:r.action("back");break;
            case 0x11:r.game->set_ctrl_skip(true);break;
            case 0x20:case 0x0d:
                if(r.overlay=="title")r.action("start");
                else if(r.game->state().wait==Wait::Choice)r.input.choice=r.selected;
                else r.input.advance=true;
                break;
            case 0x26:if(r.selected>1)--r.selected;break;
            case 0x28:++r.selected;break;
            case 0x74:r.action("quicksave");break;
            case 0x78:r.action("quickload");break;
            default:if(event->key_code>='1' && event->key_code<='9' && r.game->state().wait==Wait::Choice)r.input.choice=static_cast<unsigned>(event->key_code-'0');break;
            }
        } else if(event->type==ENGINE_INPUT_EVENT_KEY_UP && event->key_code==0x11)r.game->set_ctrl_skip(false);
        else if(event->type==ENGINE_INPUT_EVENT_POINTER_SCROLL) {
            if(r.overlay=="backlog")r.presenter->set_page(std::max(0,r.presenter->page()+(event->delta_y>0?-1:1)));
            else if(r.overlay.empty() && event->delta_y>0)r.action("backlog");
        }
    });
}
static engine_result_t menu(void* opaque,char* buffer,uint32_t size,uint32_t* written) {
    if(!opaque)return ENGINE_RESULT_INVALID_ARGUMENT;
    return copy_string(R"({"items":[{"id":"systemnnn/menu","label":"SystemNNN menu"},{"id":"systemnnn/quicksave","label":"Quick save"},{"id":"systemnnn/quickload","label":"Quick load"},{"id":"systemnnn/backlog","label":"Backlog"},{"id":"systemnnn/title","label":"Title"}]})",buffer,size,written);
}
static engine_result_t activate(void* opaque,const char* path) {
    if(!path)return ENGINE_RESULT_INVALID_ARGUMENT;
    std::string action=path;if(action.rfind("systemnnn/",0)==0)action.erase(0,10);
    return guarded(opaque,[&](Runtime& r){r.action(action);if(r.game)r.present();});
}
static engine_result_t response(void* opaque,const char* operation,const char* argument) {
    if(!operation || !argument)return ENGINE_RESULT_INVALID_ARGUMENT;
    return guarded(opaque,[&](Runtime& r){
        if(std::string(operation)!="runtime_form" || !r.text_request || !r.game->state().modal)throw std::invalid_argument("No matching text request");
        const auto modal=*r.game->state().modal;
        const auto value=Json::parse(argument);const bool accepted=value.value("result",std::string{})=="1";
        std::vector<std::string> fields;
        if(accepted){
            const auto values=value.at("values");const auto count=std::clamp<std::size_t>(modal.byte_limits.size(),1,8);
            for(std::size_t i=0;i<count;++i)fields.push_back(r.text.encode(r.text.decode_utf8(values.value("field"+std::to_string(i),std::string{})),modal.byte_limits.empty()?256:modal.byte_limits[i]));
        }
        r.game->complete_modal(modal.request,accepted,0,fields);r.text_request=false;r.present();
    });
}
static engine_result_t text_state(void* opaque,uint32_t* flags) {
    if(!opaque || !flags)return ENGINE_RESULT_INVALID_ARGUMENT;
    auto& r=*static_cast<Runtime*>(opaque);std::lock_guard<std::mutex> guard(r.game_mutex);
    *flags=r.text_request?ENGINE_TEXT_INPUT_STATE_ACTIVE:0;return ENGINE_RESULT_OK;
}
static engine_result_t renderer(void* opaque,char* buffer,uint32_t size) {
    if(!opaque)return ENGINE_RESULT_INVALID_ARGUMENT;
    return copy_string("SystemNNN Emberfall | CPU RGBA / FreeType / OpenAL",buffer,size);
}
static engine_result_t debug(void* opaque,char* buffer,uint32_t size,uint32_t* written) {
    if(!opaque)return ENGINE_RESULT_INVALID_ARGUMENT;
    auto& r=*static_cast<Runtime*>(opaque);std::lock_guard<std::mutex> guard(r.game_mutex);
    Json data={{"runtime","systemnnn"},{"overlay",r.overlay},{"paused",r.paused},{"frame_serial",r.serial},{"audio_error",r.audio.error()}};
    if(r.game){const auto& state=r.game->state();data["script"]=utf8(r.text.decode(state.script));data["word"]=state.word;data["wait"]=static_cast<int>(state.wait);data["warnings"]=r.game->warnings();}
    return copy_string(data.dump(),buffer,size,written);
}
static const engine_runtime_provider_v1_t& provider() {
    static const auto value=[] {engine_runtime_provider_v1_t p{};
        p.struct_size=sizeof(p);p.api_version=ENGINE_RUNTIME_PROVIDER_API_VERSION;
        p.runtime_id_utf8="systemnnn";p.display_name_utf8="SystemNNN (Emberfall)";p.priority=100;
        p.probe=probe;p.create=create;p.destroy=[](void* r){delete static_cast<Runtime*>(r);};
        p.open_game=open;p.tick=tick;p.pause=pause;p.resume=resume;p.set_option=option;p.set_surface_size=surface;
        p.get_frame_desc=describe;p.read_frame_rgba=read_frame;p.send_input=send_input;
        p.get_main_menu_json=menu;p.activate_menu_item=activate;p.get_renderer_info=renderer;p.get_plugin_debug_info=debug;
        p.submit_platform_response=response;p.get_text_input_state=text_state;
        p.get_frame_rendered_flag=[](void* opaque,uint32_t* rendered){if(!opaque || !rendered)return ENGINE_RESULT_INVALID_ARGUMENT;*rendered=static_cast<Runtime*>(opaque)->frame?1:0;return ENGINE_RESULT_OK;};
        p.get_last_error=[](void* opaque)->const char*{return opaque?static_cast<Runtime*>(opaque)->error.c_str():"Invalid SystemNNN runtime";};
        return p;}();return value;
}
} // namespace aether::systemnnn
extern "C" engine_result_t aether_systemnnn_register_runtime(void) {
    return engine_register_runtime_provider(&aether::systemnnn::provider());
}
