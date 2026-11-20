#include "systemnnn_startup.h"
#include "emberfall/game_session.hpp"
#include "emberfall/render.hpp"
#include "nnn/game_config.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <stdexcept>
#include <string_view>
#include <unordered_map>

namespace aether::systemnnn {
namespace {
using emberfall::scene::GameSession;
using emberfall::scene::Wait;
using emberfall::render::Surface;
using emberfall::render::Texture;
using Color=std::array<unsigned char,3>;
bool space(char c) { return c==' ' || c=='	'; }
std::string trim(std::string_view s) {
    while(!s.empty() && space(s.front()))s.remove_prefix(1);
    while(!s.empty() && space(s.back()))s.remove_suffix(1);
    return std::string(s);
}
std::string lower(std::string s) { return nnn::game_config::ascii_lower(std::move(s)); }
// Same byte grammar as GameUiAssets.readConfigFile: first field wins, ASCII
// keys only, space/tab separators, no quote stripping or inline comment removal.
// Values retain CP932/sjis_ext bytes, including low-byte tunnel pairs.
struct StartupConfig {
    std::unordered_map<std::string,std::string> values;
    std::string value(const std::string& key,std::string fallback={}) const {
        const auto i=values.find(lower(key));return i==values.end()?fallback:i->second;
    }
    int number(const std::string& key,int fallback=0) const {
        auto text=trim(value(key));auto end=text.find_first_of(" 	");
        if(end!=std::string::npos)text.resize(end);
        if(text.empty())return fallback;
        const char* begin=text.data();if(*begin=='+') {++begin;if(begin==text.data()+text.size()||*begin<'0'||*begin>'9')return fallback;}
        int n=0;const auto r=std::from_chars(begin,text.data()+text.size(),n);
        return r.ec==std::errc{} && r.ptr==text.data()+text.size()?n:fallback;
    }
    Color color(const std::string& prefix,int fallback=0) const {
        return {static_cast<unsigned char>(std::clamp(number(prefix+"R",fallback),0,255)),
                static_cast<unsigned char>(std::clamp(number(prefix+"G",fallback),0,255)),
                static_cast<unsigned char>(std::clamp(number(prefix+"B",fallback),0,255))};
    }
};
StartupConfig read_config(const std::filesystem::path& root,const std::string& name) {
    StartupConfig config;
    const auto source=nnn::game_config::read(root,"init",name+".xtx");
    std::size_t at=0;
    while(at<source.size()) {
        const auto end=source.find_first_of("\r\n",at);
        const auto line=trim(std::string_view(source).substr(at,end==std::string::npos?source.size()-at:end-at));
        const auto split=line.find_first_of(" 	");
        if(split!=std::string::npos) {
            auto key=line.substr(0,split);bool valid=!key.empty();
            for(char c:key)if(!((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='_'))valid=false;
            if(valid)config.values.emplace(lower(key),trim(std::string_view(line).substr(split)));
        }
        if(end==std::string::npos)break;
        at=end+1;if(source[end]=='\r' && at<source.size() && source[at]=='\n')++at;
    }
    return config;
}
std::string image_key(std::string value) {
    value=nnn::resource::fold_cp932(nnn::resource::normalize_cp932_path(trim(value)));
    if(value.size()>=4 && value.compare(value.size()-4,4,".dwq")==0)value.resize(value.size()-4);
    if(!value.empty() && value.find('/')==std::string::npos)value="sys/"+value;
    return value;
}
enum class Stage { Logo,Opening,Movie,Title };
Stage mode(std::string text,bool& valid) {
    text=lower(trim(text));const auto end=text.find_first_of(" 	");if(end!=std::string::npos)text.resize(end);
    valid=true;
    if(text=="logo"||text=="2")return Stage::Logo;
    if(text=="opening"||text=="3")return Stage::Opening;
    if(text=="printmovie"||text=="27")return Stage::Movie;
    if(text=="title"||text=="4")return Stage::Title;
    valid=false;return Stage::Title;
}
const char* stage_name(Stage s) {
    switch(s){case Stage::Logo:return "logo";case Stage::Opening:return "opening";case Stage::Movie:return "printMovie";default:return "title";}
}
bool valid_surface(const Surface& s) {
    return s.width && s.height && s.width<=emberfall::render::max_dimension && s.height<=emberfall::render::max_dimension &&
           std::uint64_t(s.width)*s.height<=emberfall::render::max_pixels && s.rgb.size()==std::size_t(s.width)*s.height*3;
}
Surface solid(unsigned w,unsigned h,Color color) {
    Surface s{w,h,std::vector<unsigned char>(std::size_t(w)*h*3)};
    for(std::size_t i=0;i<s.rgb.size();i+=3)std::copy(color.begin(),color.end(),s.rgb.begin()+i);
    return s;
}
void mix(Surface& out,const Surface& before,const Surface& after,unsigned alpha) {
    out=after;
    for(std::size_t i=0;i<out.rgb.size();++i)
        out.rgb[i]=static_cast<unsigned char>((unsigned(before.rgb[i])*(255-alpha)+unsigned(after.rgb[i])*alpha+127)/255);
}
// LogoPanel stretches each complete canvas to the viewport. Preserve DWQ cut
// margins and alpha rather than stretching only the stored visible rectangle.
Surface logo_frame(const Texture& t,unsigned w,unsigned h,Color color,unsigned opacity) {
    auto out=solid(w,h,color);
    for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x) {
        const int sx=static_cast<int>(std::uint64_t(x)*t.canvas_width/w)-t.content.x;
        const int sy=static_cast<int>(std::uint64_t(y)*t.canvas_height/h)-t.content.y;
        if(sx<0||sy<0||sx>=t.content.width||sy>=t.content.height)continue;
        const auto src=(std::size_t(sy)*t.pixels.width+sx)*4,dst=(std::size_t(y)*w+x)*3;
        const unsigned alpha=(unsigned(t.pixels.rgba[src+3])*opacity+127)/255;
        for(unsigned c=0;c<3;++c)out.rgb[dst+c]=static_cast<unsigned char>((unsigned(t.pixels.rgba[src+c])*alpha+unsigned(color[c])*(255-alpha)+127)/255);
    }
    return out;
}
struct Fade {
    int type=0;
    unsigned frames=0;
    bool skip=true,exiting=false;
    Color color{};
    std::uint64_t elapsed=0;
    Surface before,after;
    void configure(const StartupConfig& cfg,bool exit,unsigned period,const Surface& previous,const Surface& target) {
        const std::string prefix=exit?"exitFadeOut":"enterFadeIn";
        type=cfg.number(prefix+"Type",0);exiting=exit;
        const bool supported=(type>=1&&type<=96)||(!exit&&type==-1);
        frames=supported?static_cast<unsigned>(std::clamp(cfg.number(prefix+"Time",10),0,1000)):0;
        skip=cfg.number(prefix+"SkipOkFlag",1)!=0;color=cfg.color(prefix+"Color");elapsed=0;
        before=previous;after=target;
        if(exit)after=solid(target.width,target.height,color);
        else if(type==-1)before=solid(target.width,target.height,color);
        // UiOpening type 1 with no captured previous frame is transparent.
        if(!valid_surface(before)||before.width!=target.width||before.height!=target.height)before=target;
        (void)period;
    }
    bool running(unsigned period) const {return elapsed<std::uint64_t(frames)*period;}
    void tick(std::uint32_t dt,bool advance,unsigned period) {
        elapsed+=dt;if(advance&&skip)elapsed=std::max(elapsed,std::uint64_t(frames)*period);
    }
    void draw(Surface& out,unsigned period) const {
        if(!running(period)){out=after;return;}
        const unsigned last=std::max(1U,frames-(exiting?1U:0U));
        const unsigned at=static_cast<unsigned>(std::min<std::uint64_t>(elapsed/period,last));
        if(type>1 && emberfall::render::supports_wipe(type-1))emberfall::render::draw_wipe(out,before,after,type-1,at,last);
        else mix(out,before,after,at*255/last);
    }
};
}

struct StartupSequence::Impl {
    enum class Phase { Idle,Logo,OpeningEnter,Opening,OpeningExit,Movie,NeedTitle,TitleEnter,Done };
    struct Slide {std::shared_ptr<const Texture> image;unsigned in=0,hold=0,out=0;Color in_color{},out_color{};bool skip=true,capture=true;};
    std::filesystem::path root;
    std::unique_ptr<GameSession> background;
    GameSession* shared=nullptr;
    Phase phase=Phase::Idle;
    Stage stage=Stage::Title;
    std::array<bool,4> visited{};
    StartupConfig config;
    std::vector<std::string> notes;
    std::vector<Slide> slides;
    std::size_t slide=0;
    std::uint64_t elapsed=0,title_elapsed=0;
    unsigned width=0,height=0,period=20,default_period=20,title_delay=0;
    bool scripted=false,loop=false;
    Surface output,previous,base;
    Fade fade;
    std::optional<StartupMovieRequest> movie;
    explicit Impl(std::filesystem::path path):root(std::move(path)){}
    void warn(std::string text){if(std::find(notes.begin(),notes.end(),text)==notes.end())notes.push_back(std::move(text));}
    StartupConfig read(const std::string& name) {
        try{return read_config(root,name);}catch(const std::exception& e){warn("Startup configuration "+name+": "+e.what());return {};}
    }
    Stage next(const StartupConfig& cfg,const std::string& fallback="title") {
        const auto text=cfg.value("nextMode",fallback);bool valid=false;const auto result=mode(text,valid);
        if(!valid&&!text.empty())warn("Unsupported startup nextMode: "+text);
        return result;
    }
    unsigned logo_time(const std::string& key,int index,int fallback) const {
        int n=config.number("default"+key,fallback);
        if(config.number("useCustomTimeFlag",0)!=0)n=config.number(key+std::to_string(index),n);
        return static_cast<unsigned>(std::clamp(n,0,10000));
    }
    Color logo_color(const std::string& key,int index) const {
        Color color{};unsigned i=0;
        for(const auto* channel:{"R","G","B"}) {
            int n=config.number("default"+key+channel,255);
            if(config.number("useCustomColorFlag",0)!=0)n=config.number(key+channel+std::to_string(index),n);
            color[i++]=static_cast<unsigned char>(std::clamp(n,0,255));
        }
        return color;
    }
    bool start_logo() {
        slides.clear();slide=0;elapsed=0;std::uint64_t pixels=0;
        for(int i=1;i<=std::min(8,config.number("logoNumber",1));++i) {
            auto key=image_key(config.value("filename"+std::to_string(i)));if(key.empty())continue;
            try {
                auto t=background->ui_texture(key);
                if(!t||t->canvas_width<=0||t->canvas_height<=0)continue;
                const auto size=std::uint64_t(t->canvas_width)*t->canvas_height;
                if(size>2U*1024U*1024U||pixels+size+2>4000000U){warn("Startup logo pixel budget exceeded: "+key);continue;}
                pixels+=size+2;
                slides.push_back({std::move(t),logo_time("FadeInTime",i,20),logo_time("KeepTime",i,20),logo_time("FadeOutTime",i,10),
                    logo_color("FadeInColor",i),logo_color("FadeOutColor",i),
                    config.number("useCustomSkipFlag",0)==0||config.number("skipOK"+std::to_string(i),1)!=0,
                    config.number("createExitScreenFlag",1)!=0||config.number("exitFadeOutType",0)!=0});
            }catch(const std::exception& e){warn("Startup logo "+key+": "+e.what());}
        }
        if(slides.empty())return false;
        background->start_ui_background({},2);phase=Phase::Logo;draw_logo();return true;
    }
    void draw_logo() {
        const auto& s=slides[slide];const auto in=std::uint64_t(s.in)*period,hold=std::uint64_t(s.hold)*period,out=std::uint64_t(s.out)*period;
        unsigned alpha=255;
        if(elapsed<in)alpha=static_cast<unsigned>((elapsed*255+in/2)/in);
        else if(elapsed>=in+hold)alpha=out?static_cast<unsigned>((std::min(out,in+hold+out-std::min(elapsed,in+hold+out))*255+out/2)/out):255;
        output=logo_frame(*s.image,width,height,elapsed<in?s.in_color:s.out_color,alpha);
    }
    void leave_logo() {
        const auto& s=slides[slide];
        if(slide+1<slides.size()){++slide;elapsed=0;draw_logo();return;}
        previous=s.capture?(s.out?solid(width,height,s.out_color):logo_frame(*s.image,width,height,s.out_color,255)):Surface{};
        enter(next(config));
    }
    bool start_opening() {
        scripted=config.number("backScriptFlag",0)!=0;loop=config.number("backScriptLoopFlag",0)!=0;
        const auto script=scripted?config.value("backScriptName"):std::string{};
        const auto key=scripted?std::string{}:image_key(config.value("filenameBG"));
        background->start_ui_background(script,3,true);
        if(!script.empty()) {
            warn("Startup decorative scripts execute with native preview audio disabled; opening bgmNumber plays through the shared session.");
            const auto& state=background->step_ui_background({},loop);
            if(state.wait==Wait::Error)throw std::runtime_error(state.error);
            base=background->surface();
        } else {
            scripted=false;if(key.empty())return false;
            const auto t=background->ui_texture(key);if(!t)return false;
            base=solid(width,height,{});
            // Static opening backgrounds retain native canvas coordinates.
            emberfall::render::blit(t->pixels,base,{0,0,t->content.width,t->content.height},{t->content.x,t->content.y},emberfall::render::BlendProfile::Source64Cpp);
        }
        const int bgm=config.number("bgmNumber",-1);
        if(bgm>=0) {
            const auto error=shared->audio().play_menu_music(bgm,config.number("bgmLoop",0),config.number("bgmVolume",0),config.number("bgmFadeInTime",-1),config.number("bgmRestartFlag",1)!=0);
            if(!error.empty())warn("Startup opening music: "+error);
        }
        period=std::max(1U,background->frame_ms());
        fade.configure(config,false,period,previous,base);fade.draw(output,period);
        phase=fade.running(period)?Phase::OpeningEnter:Phase::Opening;
        return true;
    }
    void leave_opening() {
        fade.configure(config,true,period,output,output);
        if(fade.running(period)){phase=Phase::OpeningExit;fade.draw(output,period);}
        else {previous=output;enter(next(config));}
    }
    bool start_movie() {
        const auto select=config.number("selectByVarFlag",0);
        int number=-1;
        if(select) {
            // windows-31j bytes for the Android default variable ムービー番号.
            const std::string default_name="\x83\x80\x81\x5b\x83\x72\x81\x5b\x94\xd4\x8d\x86";
            auto name=config.value("selectMovieVarName");if(name.empty())name=default_name;
            number=background->named_variable(name,false,-1);
        }
        if(select==-1&&number==0)return false;
        StartupMovieRequest request;
        request.filename=config.value("movieFileName","default.wmv");
        request.movie_number=number>0?static_cast<unsigned>(number):0;
        request.skippable=config.number("noSkipFlag",0)==0;
        request.fill_exit_screen=config.number("fillExitScreenFlag",1)!=0;
        const auto color=config.color("exitFadeOutColor");
        request.exit_color=(unsigned(color[0])<<16)|(unsigned(color[1])<<8)|color[2];
        shared->audio().stop_script_audio();shared->audio().play_menu_music(-1,0,0,-1,true);
        movie=std::move(request);output=solid(width,height,{});phase=Phase::Movie;return true;
    }
    void enter(Stage target) {
        // At most three non-title modes can be visited. Repeated modes and bad
        // chains terminate at title, including chains of absent/missing assets.
        for(unsigned guard=0;guard<4;++guard) {
            stage=target;
            if(target==Stage::Title){config=read("title");phase=Phase::NeedTitle;return;}
            const auto index=static_cast<std::size_t>(target);
            if(visited[index]){warn(std::string("Repeated startup mode: ")+stage_name(target));target=Stage::Title;continue;}
            visited[index]=true;config=read(stage_name(target));
            try {
                if(target==Stage::Logo&&start_logo())return;
                if(target==Stage::Opening&&start_opening())return;
                if(target==Stage::Movie&&start_movie())return;
            }catch(const std::exception& e){warn(std::string("Startup ")+stage_name(target)+": "+e.what());}
            target=next(config);
        }
        config=read("title");phase=Phase::NeedTitle;
    }
};

StartupSequence::StartupSequence(const std::filesystem::path& root):impl_(std::make_unique<Impl>(root)){}
StartupSequence::~StartupSequence()=default;
void StartupSequence::start(GameSession& shared,const GameSession* peer) {
    start(shared,emberfall::scene::SessionOptions{},peer);
}
void StartupSequence::start(GameSession& shared,const emberfall::scene::SessionOptions& source_options,const GameSession* peer) {
    auto root=impl_->root;impl_=std::make_unique<Impl>(std::move(root));auto& i=*impl_;i.shared=&shared;
    const auto dimensions=shared.shared_config_snapshot();
    if(dimensions.screen_width<=0||dimensions.screen_height<=0||dimensions.screen_width>int(emberfall::render::max_dimension)||dimensions.screen_height>int(emberfall::render::max_dimension)||
       std::uint64_t(dimensions.screen_width)*dimensions.screen_height>emberfall::render::max_pixels)throw std::runtime_error("Invalid startup surface dimensions");
    i.width=static_cast<unsigned>(dimensions.screen_width);i.height=static_cast<unsigned>(dimensions.screen_height);i.period=i.default_period=static_cast<unsigned>(std::max(1,dimensions.default_frame_ms));
    auto options=source_options;options.runtime=shared.runtime();options.save_layout=shared.runtime_ref().save_layout;options.analyze_executable=false;
    options.width=dimensions.screen_width;options.height=dimensions.screen_height;options.frame_ms=i.period;
    i.background=GameSession::create_ui_preview(i.root,std::move(options),peer);
    i.output=solid(i.width,i.height,{});
    const auto initial=i.read("nothing");
    if(initial.number("codecCheckFlag",0))i.warn("Startup codecCheckFlag requires parent MoviePlayer codec capability checks.");
    i.enter(i.next(initial,"logo"));
}
void StartupSequence::tick(std::uint32_t dt,bool advance) {
    auto& i=*impl_;
    switch(i.phase) {
    case Impl::Phase::Logo: {
        i.elapsed+=dt;const auto& s=i.slides[i.slide];
        if((advance&&s.skip)||i.elapsed>=std::uint64_t(s.in+s.hold+s.out)*i.period)i.leave_logo();
        else i.draw_logo();
        break;
    }
    case Impl::Phase::OpeningEnter:
        i.fade.tick(dt,advance,i.period);i.fade.draw(i.output,i.period);
        if(!i.fade.running(i.period)){i.phase=Impl::Phase::Opening;i.background->reset_frame_pacing();}
        break;
    case Impl::Phase::Opening:
        if(advance){i.leave_opening();break;}
        if(i.scripted&&dt) {
            try {
                const auto& state=i.background->tick_ui_background({},i.loop,dt);
                i.period=std::max(1U,i.background->frame_ms());i.output=i.background->surface();
                if(state.wait==Wait::Ended)i.leave_opening();
                else if(state.wait!=Wait::Running&&state.wait!=Wait::Draw&&state.wait!=Wait::Overlap) {
                    i.warn("Startup opening interrupted: "+(state.error.empty()?std::string("background waits for unsupported input"):state.error));i.leave_opening();
                }
            }catch(const std::exception& e){i.warn(std::string("Startup opening interrupted: ")+e.what());i.leave_opening();}
        }
        break;
    case Impl::Phase::OpeningExit:
        i.fade.tick(dt,advance,i.period);i.fade.draw(i.output,i.period);
        if(!i.fade.running(i.period)){i.previous=i.output;i.enter(i.next(i.config));}
        break;
    case Impl::Phase::TitleEnter: {
        const bool fading=i.fade.running(i.period);i.fade.tick(dt,advance,i.period);i.fade.draw(i.output,i.period);
        if(fading) {
            if(!i.fade.running(i.period))i.title_elapsed=0;
        }else {i.title_elapsed+=dt;if(advance)i.title_elapsed=std::uint64_t(i.title_delay)*i.period;}
        if(!i.fade.running(i.period)&&i.title_elapsed>=std::uint64_t(i.title_delay)*i.period)i.phase=Impl::Phase::Done;
        break;
    }
    default:break;
    }
}
bool StartupSequence::finished() const noexcept{return impl_->phase==Impl::Phase::Done;}
bool StartupSequence::awaiting_movie() const noexcept{return impl_->phase==Impl::Phase::Movie;}
const std::optional<StartupMovieRequest>& StartupSequence::movie_request() const noexcept{return impl_->movie;}
void StartupSequence::finish_movie() {
    auto& i=*impl_;if(!awaiting_movie())return;
    if(i.movie->fill_exit_screen) {
        const auto color=i.movie->exit_color;
        i.previous=solid(i.width,i.height,{static_cast<unsigned char>(color>>16),static_cast<unsigned char>(color>>8),static_cast<unsigned char>(color)});
        i.output=i.previous;
    }
    i.movie.reset();i.enter(i.next(i.config));
}
bool StartupSequence::awaiting_title() const noexcept{return impl_->phase==Impl::Phase::NeedTitle;}
void StartupSequence::begin_title(const Surface& title) {
    auto& i=*impl_;if(!awaiting_title())return;
    if(!valid_surface(title)||title.width!=i.width||title.height!=i.height)throw std::invalid_argument("Startup title frame dimensions differ from game");
    i.period=i.default_period;
    i.base=title;i.fade.configure(i.config,false,i.period,i.previous,title);i.fade.draw(i.output,i.period);
    i.title_elapsed=0;
    i.title_delay=static_cast<unsigned>(std::clamp(i.config.number("menuStartWaitTime",0),0,1000)+std::clamp(i.config.number("menuStartEffectTime",0),0,1000));
    if(i.config.number("menuStartEffectType",0)!=0 && i.config.number("menuStartEffectTime",0)>0)
        i.warn("Startup title entrance honors menu reveal timing; per-button reveal transforms require Presenter integration.");
    i.phase=(i.fade.running(i.period)||i.title_delay)?Impl::Phase::TitleEnter:Impl::Phase::Done;
}
const Surface* StartupSequence::frame() const noexcept{return impl_->output.rgb.empty()?nullptr:&impl_->output;}
GameSession* StartupSequence::session() noexcept{return impl_->background.get();}
GameSession* StartupSequence::audio_session() noexcept{return impl_->shared;}
const std::vector<std::string>& StartupSequence::warnings() const noexcept{return impl_->notes;}
} // namespace aether::systemnnn
