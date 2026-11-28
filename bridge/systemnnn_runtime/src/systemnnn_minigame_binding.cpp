#include "systemnnn_minigame_binding.h"
#include "nnn/game_config.hpp"
#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstdio>
#include <map>
#include <set>
#include <stdexcept>

namespace aether::systemnnn {
namespace minigame_binding_detail {
using Game=emberfall::scene::GameSession;
using Image=minigame::Image;
using Picture=std::shared_ptr<const Image>;
bool space(char c){return c==' '||c=='\t'||c=='\r'||c=='\n';}
bool lead(unsigned char c){return (c>=0x81&&c<=0x9f)||(c>=0xe0&&c<=0xfc);}
std::string trim(std::string_view s){while(!s.empty()&&space(s.front()))s.remove_prefix(1);while(!s.empty()&&space(s.back()))s.remove_suffix(1);return std::string(s);}
std::string lower(std::string s){for(char& c:s)if(c>='A'&&c<='Z')c=char(c+32);return s;}
struct Setup {
    std::map<std::string,std::string> values;
    explicit Setup(std::string_view source={}){
        std::size_t start=0;
        while(start<source.size()){
            const auto end=source.find_first_of("\r\n",start);
            const auto line=source.substr(start,end==source.npos?source.size()-start:end-start);
            std::size_t at=0;while(at<line.size()&&space(line[at]))++at;
            const auto begin=at;while(at<line.size()&&!space(line[at]))++at;
            const auto key=line.substr(begin,at-begin);
            bool valid=!key.empty();for(char c:key)if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'))valid=false;
            while(at<line.size()&&space(line[at]))++at;
            if(valid&&at<line.size())values.emplace(lower(std::string(key)),trim(line.substr(at)));
            if(end==source.npos)break;
            start=end+1;
        }
    }
    std::string value(std::string_view key,std::string_view fallback={})const{auto it=values.find(lower(std::string(key)));return it==values.end()?std::string(fallback):it->second;}
    int number(std::string_view key,int fallback)const{
        const auto s=value(key);int n=0;const auto r=std::from_chars(s.data(),s.data()+s.size(),n);
        return r.ec==std::errc()&&r.ptr==s.data()+s.size()?n:fallback;
    }
};
Setup setup(const std::filesystem::path& root,const char* name){return Setup(nnn::game_config::read(root,"init",std::string(name)+".xtx"));}
std::string image_key(std::string s){
    s=trim(s);
    for(std::size_t i=0;i<s.size();++i){
        if(lead(static_cast<unsigned char>(s[i]))&&i+1<s.size()){
            const auto trail=static_cast<unsigned char>(s[i+1]);if(trail>=0x40&&trail<=0xfc&&trail!=0x7f){++i;continue;}
        }
        if(s[i]=='\\')s[i]='/';else if(s[i]>='A'&&s[i]<='Z')s[i]=char(s[i]+32);
    }
    if(s.size()>=4&&s.compare(s.size()-4,4,".dwq")==0)s.resize(s.size()-4);
    return s;
}
std::string system_key(std::string s){s=image_key(std::move(s));if(!s.empty()&&s.find('/')==s.npos)s="sys/"+s;return s;}
// JNI ui_sprite: preserve canvas, cut margins and original alpha. No color key.
Picture texture_image(const emberfall::render::Texture& t,std::uint64_t max_pixels){
    const int w=t.canvas_width,h=t.canvas_height;
    if(w<=0||h<=0||static_cast<std::uint64_t>(w)*h>max_pixels)return {};
    auto out=std::make_shared<Image>();out->width=w;out->height=h;out->rgba.resize(static_cast<std::size_t>(w)*h*4);
    for(unsigned y=0;y<t.pixels.height;++y)for(unsigned x=0;x<t.pixels.width;++x){
        const auto dx=static_cast<long long>(x)+t.content.x,dy=static_cast<long long>(y)+t.content.y;
        const auto src=(static_cast<std::size_t>(y)*t.pixels.width+x)*4;
        if(dx<0||dy<0||dx>=w||dy>=h||src+4>t.pixels.rgba.size())continue;
        const auto dst=(static_cast<std::size_t>(dy)*w+static_cast<std::size_t>(dx))*4;
        std::copy_n(t.pixels.rgba.data()+src,4,out->rgba.data()+dst);
    }
    return out;
}
Picture picture(Game& game,const std::string& name,bool large){
    if(name.empty())return {};
    try{const auto t=game.ui_texture(name);return t?texture_image(*t,large?6U*1024U*1024U:2U*1024U*1024U):Picture{};}
    catch(const std::exception&){return {};}// Missing optional art is legal, matching JNI.
}
std::size_t prefix(std::string_view s,std::size_t p){for(char c:{'*','@','!'})if(p<s.size()&&s[p]==c)++p;return p;}
std::size_t digits(std::string_view s,std::size_t p){while(p<s.size()&&s[p]>='0'&&s[p]<='9')++p;return p;}
bool animation_comma(std::string_view s,std::size_t start,std::size_t comma){
    const auto p=prefix(s,start);if(p>=s.size()||s[p]!='#'||digits(s,p+1)!=comma||p+1==comma)return false;
    const auto end=digits(s,comma+1);return end>comma+1&&end<s.size()&&s[end]=='/';
}
std::vector<std::string> cg_tokens(std::string_view s){
    if(s.find('\0')!=s.npos)throw std::runtime_error("CG list contains NUL");
    std::vector<std::string> out;std::size_t p=0;
    while(p<s.size()){
        if(s[p]==',')++p;
        while(p<s.size()&&space(s[p]))++p;
        if(p==s.size())break;
        const auto start=p;
        while(p<s.size()){
            if(space(s[p])||(s[p]==','&&!animation_comma(s,start,p)))break;
            p+=lead(static_cast<unsigned char>(s[p]))&&p+1<s.size()?2:1;
        }
        if(p-start>255||out.size()==65536)throw std::runtime_error("CG list exceeds format bounds");
        out.emplace_back(s.substr(start,p-start));
    }
    return out;
}
std::vector<std::string> gallery_choices(const std::filesystem::path& root,const std::vector<nnn::Word>& keys,const Setup& config){
    const std::set<nnn::Word> unlocked(keys.begin(),keys.end());
    std::set<std::string> seen;std::vector<std::string> choices;std::size_t total=0;
    for(unsigned group=0;group<80;++group){
        char list[32];std::snprintf(list,sizeof(list),"cglist%02u.xtx",group+1);
        const auto text=nnn::game_config::read(root,"spt",list);const auto names=cg_tokens(text);
        if(names.empty())break;
        total+=names.size();if(total>16384)throw std::runtime_error("CG lists exceed gallery capacity");
        for(std::size_t i=0;i<names.size();++i){
            if(!unlocked.count(0x10000000U|(group<<16U)|static_cast<nnn::Word>(i)))continue;
            const auto& raw=names[i];const bool gore=!raw.empty()&&raw[0]=='*';
            const bool difference=raw.size()>(gore?1U:0U)&&raw[gore?1:0]=='@';
            std::size_t p=prefix(raw,0);
            if(p<raw.size()&&raw[p]=='#'){const auto slash=raw.find('/',p+1);if(slash!=raw.npos)p=slash+1;}
            if(p<raw.size()&&raw[p]=='['){const auto end=raw.find(']',p+1);if(end!=raw.npos)p=end+1;}
            auto name=raw.substr(p);
            if((difference&&!config.number("sabunOkFlag",0))||(!config.number("allOkFlag",0)&&!name.empty()&&name[0]=='!')||lower(name.substr(0,2))=="ta")continue;
            name=image_key(std::move(name));if(name.size()>=2&&name.find('/')==name.npos)name=name.substr(0,2)+"/"+name;
            if(seen.insert(name).second)choices.push_back(std::move(name));
        }
    }
    return choices;
}
void music(Game& game,const Setup& cfg,int default_number,std::vector<std::string>& warnings){
    try {
        const auto error=game.audio().play_menu_music(cfg.number("bgmNumber",default_number),cfg.number("bgmLoop",0),cfg.number("bgmVolume",0),cfg.number("bgmFadeInTime",-1),cfg.number("bgmRestartFlag",1)!=0);
        if(!error.empty())warnings.push_back("Minigame music: "+error);
    } catch(const std::exception& e) {warnings.push_back(std::string("Minigame music: ")+e.what());}
}
} // namespace minigame_binding_detail
using namespace minigame_binding_detail;
struct MiniGameBinding::Impl {
    std::unique_ptr<minigame::Frontend> ui;
    Setup caller_config;
    unsigned index=0;
    int caller_default=1;
    std::vector<std::string> warnings;
};
MiniGameBinding::MiniGameBinding():impl_(std::make_unique<Impl>()){}
MiniGameBinding::~MiniGameBinding()=default;
bool MiniGameBinding::active()const noexcept{return bool(impl_->ui);}
const minigame::Frontend* MiniGameBinding::frontend()const noexcept{return impl_->ui.get();}
void MiniGameBinding::start(unsigned index,Game& game,std::string caller,std::uint64_t seed){
    if(active())throw std::logic_error("Minigame already active");
    const auto runtime=game.runtime();if(!runtime)throw std::runtime_error("Minigame requires runtime context");
    const auto& root=runtime->root();const auto cfg=std::make_shared<Setup>(setup(root,"minigame"));
    const auto tag="miniGame"+std::to_string(index+1);const int type=cfg->number(tag,0);
    if(index>=64||index>=static_cast<unsigned>(std::max(0,cfg->number("addMiniGame",0)))||type<1||type>10)throw std::runtime_error("Minigame configuration unavailable");
    caller=lower(caller);
    if(caller!="title"&&caller!="omake")throw std::invalid_argument("Unknown minigame caller");
    const auto caller_cfg=setup(root,caller=="omake"?"omake":"title");
    if(!caller_cfg.number("miniGameFlag",0))throw std::runtime_error("Minigames disabled in caller menu");
    const int checks=std::clamp(cfg->number("miniGameCheckNumber",cfg->number("addMiniGame",0)),0,std::clamp(cfg->number("addMiniGame",0),0,64));
    std::string mode="omake";
    for(unsigned n=1;n<=index+1;++n)mode=cfg->value("miniGameCheckMode"+std::to_string(n),mode);
    if(index>=static_cast<unsigned>(checks)||(lower(mode)!=caller&&mode!=(caller=="title"?"4":"15")))throw std::runtime_error("Minigame entry unavailable in caller menu");
    const auto variable=cfg->value("checkVarName"+std::to_string(index+1));
    if(!variable.empty()&&game.named_variable(variable,true)==0&&game.named_variable(variable,false,-1)!=-1)throw std::runtime_error("Minigame entry is locked");
    if(seed==0)seed=static_cast<std::uint64_t>(std::chrono::steady_clock::now().time_since_epoch().count());
    minigame::Assets assets;
    auto choices=gallery_choices(root,runtime->snapshot_gallery(),*cfg);
    minigame::Random random(seed);for(std::size_t n=choices.size();n>1;--n)std::swap(choices[n-1],choices[static_cast<std::size_t>(random.next(static_cast<int>(n)))]);
    for(const auto& name:choices){auto image=picture(game,name,true);if(!image)continue;if(!assets.first)assets.first=std::move(image);else{assets.second=std::move(image);break;}}
    if(!assets.first)assets.first=picture(game,system_key(cfg->value("noCGFileName","nnnlogo")),true);
    if(type>=minigame::Monte&&type<=minigame::Golf)assets.trump=picture(game,system_key(cfg->value("trumpPicFileName")),false);
    if(type>=minigame::Nikaku)assets.mahjong=picture(game,system_key(cfg->value("mahjongPicFileName")),false);
    assets.exit=picture(game,system_key(cfg->value("exitFileName")),false);
    assets.congratulations=picture(game,system_key(cfg->value("congraFileName","ta_congra")),false);
    for(int page=1;page<=std::clamp(cfg->number("miniGameDescNumber"+std::to_string(index+1),0),0,16);++page){
        auto image=picture(game,system_key(cfg->value("miniGameDescFileName"+std::to_string(index+1)+"_"+std::to_string(page),"bg_desc")),true);
        if(image)assets.instructions.push_back(std::move(image));
    }
    const auto surface=game.surface();minigame::Options opts;opts.type=type;opts.index=static_cast<int>(index);opts.seed=seed;
    opts.width=static_cast<int>(surface.width);opts.height=static_cast<int>(surface.height);opts.frame_ms=static_cast<int>(game.frame_ms());
    opts.number=[cfg](std::string_view key,int fallback){return cfg->number(key,fallback);};
    auto ui=std::make_unique<minigame::Frontend>(std::move(opts),std::move(assets));
    impl_->caller_config=caller_cfg;impl_->caller_default=1;impl_->index=index;impl_->ui=std::move(ui);
    music(game,*cfg,1,impl_->warnings);
}
void MiniGameBinding::pointer(minigame::Pointer event,float x,float y,int button){if(active())impl_->ui->pointer(event,x,y,button);}
void MiniGameBinding::tick(std::uint32_t ms){if(active())impl_->ui->tick(ms);}
emberfall::render::Surface MiniGameBinding::render()const{
    emberfall::render::Surface out;if(!active())return out;
    const auto image=impl_->ui->render();out.width=static_cast<unsigned>(image.width);out.height=static_cast<unsigned>(image.height);out.rgb.resize(static_cast<std::size_t>(out.width)*out.height*3);
    for(std::size_t p=0;p<static_cast<std::size_t>(out.width)*out.height;++p)for(std::size_t c=0;c<3;++c)out.rgb[p*3+c]=image.rgba[p*4+c];
    return out;
}
MiniGameBinding::Result MiniGameBinding::dispatch(Game& game){
    Result result;if(active()){
        const auto events=impl_->ui->take_events();
        for(int sound:events.sounds){const auto error=game.audio().play_system_se(static_cast<unsigned>(sound));if(!error.empty())impl_->warnings.push_back("Minigame sound: "+error);}
        if(events.cleared)result.progress_changed=game.complete_minigame(impl_->index);
        result.exit=events.exit;if(result.exit)stop(game);
    }
    result.warnings=take_warnings();return result;
}
void MiniGameBinding::stop(Game& game,bool restore_music){if(!active())return;impl_->ui.reset();if(restore_music)music(game,impl_->caller_config,impl_->caller_default,impl_->warnings);}
std::vector<std::string> MiniGameBinding::take_warnings(){auto out=std::move(impl_->warnings);impl_->warnings.clear();return out;}
} // namespace aether::systemnnn
