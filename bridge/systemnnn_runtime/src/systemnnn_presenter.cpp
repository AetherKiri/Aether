#include "systemnnn_presenter.h"
#include "systemnnn_text.h"

#include "emberfall/game_session.hpp"
#include "nnn/game_config.hpp"

#include <algorithm>
#include <array>
#include <charconv>
#include <climits>
#include <cmath>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <utility>

namespace aether::systemnnn {
namespace {
namespace scene = emberfall::scene;
namespace render = emberfall::render;
using Plane = render::MessagePlane;
using Texture = render::Texture;
using Rect = render::Rect;

std::string lower(std::string_view s) {
    std::string out(s);
    for (char& c : out) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return out;
}
bool spacing(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
std::string trim(std::string_view s) {
    while (!s.empty() && spacing(s.front())) s.remove_prefix(1);
    while (!s.empty() && spacing(s.back())) s.remove_suffix(1);
    return std::string(s);
}
std::string image_key(std::string name) {
    // A CP932 trail byte may equal '\\'; do not turn it into a separator.
    for(std::size_t i=0;i<name.size();++i) {
        const auto c=static_cast<unsigned char>(name[i]);
        if(((c>=0x81 && c<=0x9f) || (c>=0xe0 && c<=0xfc)) && i+1<name.size()) {
            const auto trail=static_cast<unsigned char>(name[i+1]);
            if(trail>=0x40 && trail<=0xfc && trail!=0x7f) {++i;continue;}
        }
        if(name[i]=='\\')name[i]='/';
    }
    if (name.size() >= 4 && lower(std::string_view(name).substr(name.size()-4)) == ".dwq") name.resize(name.size()-4);
    if (!name.empty() && name.find('/') == std::string::npos) name = "sys/" + name;
    return name;
}
int bound(int n, int low, int high) { return std::max(low, std::min(n, high)); }
int dimension(int n) { return bound(n, 1, 4096); }
int safe_add(int a, long long b) {
    return static_cast<int>(std::max<long long>(INT_MIN, std::min<long long>(INT_MAX, static_cast<long long>(a)+b)));
}
std::uint32_t color(const Config& c, const std::string& key, std::uint32_t fallback=0xffffffff) {
    return 0xff000000U | (static_cast<unsigned>(bound(c.number(key+"R", (fallback>>16)&255),0,255))<<16) |
        (static_cast<unsigned>(bound(c.number(key+"G", (fallback>>8)&255),0,255))<<8) |
        static_cast<unsigned>(bound(c.number(key+"B", fallback&255),0,255));
}
// Input colors are straight ARGB. MessagePlane storage is premultiplied RGBA.
void blend(Plane& p, int x, int y, unsigned r, unsigned g, unsigned b, unsigned a) {
    if (x<0 || y<0 || x>=static_cast<int>(p.width) || y>=static_cast<int>(p.height) || !a) return;
    auto* d=p.rgba.data()+static_cast<std::size_t>(y)*p.stride+static_cast<std::size_t>(x)*4;
    const unsigned inv=255-a;
    d[0]=static_cast<unsigned char>((r*a+d[0]*inv+127)/255);
    d[1]=static_cast<unsigned char>((g*a+d[1]*inv+127)/255);
    d[2]=static_cast<unsigned char>((b*a+d[2]*inv+127)/255);
    d[3]=static_cast<unsigned char>(a+(d[3]*inv+127)/255);
}
void rectangle(Plane& p, Rect r, std::uint32_t c) {
    const int right=bound(safe_add(r.x,r.width),0,static_cast<int>(p.width));
    const int bottom=bound(safe_add(r.y,r.height),0,static_cast<int>(p.height));
    for (int y=std::max(0,r.y); y<bottom; ++y)
        for (int x=std::max(0,r.x); x<right; ++x) blend(p,x,y,(c>>16)&255,(c>>8)&255,c&255,c>>24);
}
unsigned texture_alpha(const Texture& t,int x,int y) {
    x-=t.content.x; y-=t.content.y;
    if (x<0 || y<0 || x>=static_cast<int>(t.pixels.width) || y>=static_cast<int>(t.pixels.height)) return 0;
    const auto at=(static_cast<std::size_t>(y)*t.pixels.width+static_cast<unsigned>(x))*4;
    return at+3<t.pixels.rgba.size() ? t.pixels.rgba[at+3] : 0;
}
bool paint(Plane& p,const Texture& t,Rect src,int x,int y,int opacity=255) {
    if(src.width<=0 || src.height<=0 || opacity<=0) return false;
    const auto left=std::max({0LL,-static_cast<long long>(x),static_cast<long long>(t.content.x)-src.x});
    const auto top=std::max({0LL,-static_cast<long long>(y),static_cast<long long>(t.content.y)-src.y});
    const auto right=std::min({static_cast<long long>(src.width),static_cast<long long>(p.width)-x,
        static_cast<long long>(t.content.x)+t.pixels.width-src.x});
    const auto bottom=std::min({static_cast<long long>(src.height),static_cast<long long>(p.height)-y,
        static_cast<long long>(t.content.y)+t.pixels.height-src.y});
    opacity=bound(opacity,0,255);
    bool drawn=false;
    for(auto dy=top;dy<bottom;++dy) for(auto dx=left;dx<right;++dx) {
        const auto at=(static_cast<std::size_t>(src.y+dy-t.content.y)*t.pixels.width+
            static_cast<unsigned>(src.x+dx-t.content.x))*4;
        if(at+3>=t.pixels.rgba.size()) continue;
        const auto* s=t.pixels.rgba.data()+at;
        blend(p,x+dx,y+dy,s[0],s[1],s[2],(s[3]*static_cast<unsigned>(opacity)+127)/255);
        drawn=true;
    }
    return drawn;
}
// Nearest-neighbor scaling respects DWQ content offsets and never iterates outside
// the visible plane. Products use 64 bits for malformed/oversized source metadata.
bool scaled(Plane& p,const Texture& t,Rect src,Rect dst,int opacity=255) {
    if(src.width<=0 || src.height<=0 || dst.width<=0 || dst.height<=0)return false;
    bool drawn=false;
    for(int y=std::max(0,dst.y);y<std::min<long long>(p.height,static_cast<long long>(dst.y)+dst.height);++y)
        for(int x=std::max(0,dst.x);x<std::min<long long>(p.width,static_cast<long long>(dst.x)+dst.width);++x) {
            const auto sx=static_cast<long long>(src.x)+(static_cast<long long>(x)-dst.x)*src.width/dst.width-t.content.x;
            const auto sy=static_cast<long long>(src.y)+(static_cast<long long>(y)-dst.y)*src.height/dst.height-t.content.y;
            if(sx<0 || sy<0 || sx>=t.pixels.width || sy>=t.pixels.height)continue;
            const auto at=(static_cast<std::size_t>(sy)*t.pixels.width+static_cast<std::size_t>(sx))*4;
            if(at+3>=t.pixels.rgba.size())continue;
            const auto* s=t.pixels.rgba.data()+at;
            const auto alpha=s[3]*static_cast<unsigned>(bound(opacity,0,255))/255;
            blend(p,x,y,s[0],s[1],s[2],alpha);drawn|=alpha!=0;
        }
    return drawn;
}
// Sample only visible pixels; a huge offscreen road must not make drawing slow.
void road(Plane& p,int x1,int y1,int x2,int y2,std::uint32_t c) {
    const double dx=static_cast<double>(x2)-x1,dy=static_cast<double>(y2)-y1;
    double first=0,last=1;
    auto clip=[&](double a,double b) {
        if(a==0)return b>=0;
        const double t=b/a;
        if(a<0)first=std::max(first,t);else last=std::min(last,t);
        return first<=last;
    };
    if(!clip(-dx,x1+1.0)||!clip(dx,static_cast<double>(p.width)-x1)||
       !clip(-dy,y1+1.0)||!clip(dy,static_cast<double>(p.height)-y1))return;
    const int steps=std::max(1,static_cast<int>(std::ceil(std::max(std::abs(dx),std::abs(dy))*(last-first))));
    for(int i=0;i<=steps;++i) {
        const double t=first+(last-first)*i/steps;
        rectangle(p,{static_cast<int>(std::round(x1+dx*t)),static_cast<int>(std::round(y1+dy*t)),2,2},c);
    }
}
std::string modal_action(int action,int value) { return "modal:action:"+std::to_string(action)+":"+std::to_string(value); }
std::string chart_point(int x,int y) {
    const auto bits=(static_cast<std::uint32_t>(x)<<16)|(static_cast<std::uint32_t>(y)&0xffffU);
    const auto value=static_cast<std::int64_t>(bits)-(bits>INT32_MAX?0x100000000LL:0);
    return modal_action(1,static_cast<int>(value));
}
struct TextLayout { int x=0,y=0,font=24,next_x=0,next_y=30,space=1; };
struct Ruby { std::size_t start=0,end=0; std::u32string text; };
struct Markup { std::u32string text; std::vector<Ruby> ruby; };
Markup markup(std::u32string_view text, bool single_byte) {
    Markup out;
    const char32_t open=single_byte?U'[':U'［',close=single_byte?U']':U'］',em=single_byte?U'.':U'強';
    std::size_t line=0;
    for(std::size_t i=0;i<text.size();) {
        if(text[i]==U'#' && i+1<text.size()) {
            const auto command=text[i+1];
            if(command==close) {i+=2;continue;}
            if(command==open || command==em) {
                std::size_t at=i+2, count=0;
                if(command==open && at<text.size()) {
                    auto digit=text[at++];
                    if(digit>=U'1' && digit<=U'9') count=digit-U'0';
                    else if(digit>=U'１' && digit<=U'９') count=digit-U'０';
                }
                const auto begin=at;
                while(at<text.size() && text[at]!=close && text[at]!=U'\r' && text[at]!=U'\n' && at-begin<100) ++at;
                if(at<text.size() && text[at]==close && at>begin && at-begin<100 && (command==em || count)) {
                    if(command==em) count=at-begin;
                    if(count<=out.text.size()-line) out.ruby.push_back({out.text.size()-count,out.text.size(),std::u32string(text.substr(begin,at-begin))});
                    i=at+1;continue;
                }
            }
        }
        out.text.push_back(text[i++]);
        if(out.text.back()==U'\r' || out.text.back()==U'\n') line=out.text.size();
    }
    return out;
}
// Fixed cells preserve the PC's configured nextX/nextY/space and ruby anchors.
// FreeType still supplies glyph outlines; proportional advance is used in menus.
int cell_width(char32_t c,int font) { return c<0x100 ? std::max(1,font/2) : font; }
struct GlyphPosition { int x,y,row; };
}

bool Config::has(std::string_view key) const { return values_.find(lower(key))!=values_.end(); }
std::string Config::value(std::string_view key,std::string_view fallback) const {
    const auto it=values_.find(lower(key));
    return it==values_.end()?std::string(fallback):it->second;
}
int Config::number(std::string_view key,int fallback) const {
    const auto raw=trim(value(key));
    if(raw.empty()) return fallback;
    int result=0;
    // from_chars deliberately accepts only a decimal first token, like Android.
    const char* first=raw.data();
    if(*first=='+') ++first;
    const auto parsed=std::from_chars(first,raw.data()+raw.size(),result);
    return parsed.ec==std::errc{} && parsed.ptr!=first &&
        (parsed.ptr==raw.data()+raw.size() || spacing(*parsed.ptr)) ? result : fallback;
}

struct Presenter::Impl {
    std::filesystem::path root;
    TextRenderer& text;
    std::unordered_map<std::string,Config> configs;
    std::vector<std::string> notes;
    std::unordered_map<std::u32string,std::uint32_t> name_colors;
    struct Hit {
        Rect rect;
        std::string action;
        std::shared_ptr<const Texture> mask;
        int source_x=0,source_y=0;
    };
    std::vector<Hit> targets;
    int page=0;
    bool save_inventory_known=false;
    std::unordered_map<int,SaveSlotInfo> save_slots;
    // Chart hit rectangles use the exact click coordinates when packed for core.
    struct ChartHit { Rect rect; };
    std::vector<ChartHit> chart_targets;
    struct MiniHit { Rect rect; int minimum,maximum,extent; bool legacy; int viewport; };
    std::vector<MiniHit> mini_targets;
    std::string previous_view;
    int width=800,height=600;
    // Asset ownership stays with the session cache; only live hit masks pin images.
    explicit Impl(std::filesystem::path r,TextRenderer& t):root(std::move(r)),text(t) {}
    const Config& cfg(std::string_view name) const { return configs.at(lower(name)); }
    void note(std::string message) {
        if(std::find(notes.begin(),notes.end(),message)==notes.end()) notes.push_back(std::move(message));
    }
    std::u32string decode(std::string_view s,bool configuration=false) {
        try { return text.decode(s,configuration); }
        catch(const std::exception& e) { note(std::string("Text decoding failed: ")+e.what()); return U"[Text decoding failed]"; }
    }
    std::shared_ptr<const Texture> texture(scene::GameSession& game,const std::string& name) {
        if(name.empty()) return {};
        try { return game.ui_texture(image_key(name)); }
        catch(const std::exception& e) { note("UI image unavailable ("+image_key(name)+"): "+e.what()); return {}; }
    }
    bool image(Plane& plane,scene::GameSession& game,const std::string& name,int x,int y,int w=0,int h=0,int sy=0,int sx=0,int alpha=255) {
        auto asset=texture(game,name);
        if(!asset) return false;
        return paint(plane,*asset,{sx,sy,w>0?w:asset->canvas_width,h>0?h:asset->canvas_height},x,y,alpha);
    }
    void label(Plane& plane,std::u32string_view s,int x,int y,int size,int max_width,std::uint32_t c=0xffffffff) {
        text.draw(plane,s,safe_add(x,1),safe_add(y,1),dimension(size),max_width,0xb0000000);
        text.draw(plane,s,x,y,dimension(size),max_width,c);
    }
    void target(Rect bounds,std::string action) { if(bounds.width>0 && bounds.height>0) targets.push_back({bounds,std::move(action),{},0,0}); }
    void row(Plane& p,Rect r,std::u32string_view caption,std::string action,bool enabled=true,int font=22) {
        rectangle(p,r,enabled?0xdc213349:0xc52b2b30);
        rectangle(p,{r.x,r.y,r.width,1},enabled?0xc388afce:0x80606670);
        label(p,caption,safe_add(r.x,10),safe_add(r.y,5),font,std::max(1,r.width-20),enabled?0xffffffff:0xff8c929b);
        if(enabled) target(r,std::move(action));
    }
    // Read one inherited CCommonButton setup. Title buttons inherit from the previous button.
    struct Button {
        std::string image;
        int x=0,y=0,w=16,h=16,sx=0,sy=0,disabled_x=48,disabled_y=0;
        int hit_x=0,hit_y=0,hit_sx=0,hit_sy=0,hit_w=16,hit_h=16;
        bool pixels=true,enabled=true,exists=true;
    };
    Button button(const Config& c,const std::string& key,Button base) {
        base.image=c.value(key+"FileName",base.image);
        base.x=c.number(key+"PrintX",base.x);base.y=c.number(key+"PrintY",base.y);
        base.w=dimension(c.number(key+"SizeX",base.w));base.h=dimension(c.number(key+"SizeY",base.h));
        base.sx=c.number(key+"PicSrcX1",base.sx);base.sy=c.number(key+"PicSrcY1",base.sy);
        base.disabled_x=c.number(key+"PicSrcX4",base.disabled_x);base.disabled_y=c.number(key+"PicSrcY4",base.disabled_y);
        base.hit_x=c.number(key+"CheckDeltaX",base.hit_x);base.hit_y=c.number(key+"CheckDeltaY",base.hit_y);
        base.hit_sx=c.number(key+"CheckPicX",base.hit_sx);base.hit_sy=c.number(key+"CheckPicY",base.hit_sy);
        base.hit_w=dimension(c.number(key+"CheckSizeX",base.w));base.hit_h=dimension(c.number(key+"CheckSizeY",base.h));
        base.pixels=c.number(key+"PrintMode",base.pixels?2:0)!=0;
        base.exists=c.number(key+"ExistFlag",base.exists?1:0)!=0;
        base.enabled=c.number(key+"EnableFlag",base.exists&&base.enabled?1:0)!=0;
        return base;
    }
    void draw_button(Plane& p,scene::GameSession& game,const Button& b,std::u32string_view caption,const std::string& action) {
        if(!b.exists) return;
        auto asset=texture(game,b.image);
        const bool drawn=asset && paint(p,*asset,{b.enabled?b.sx:b.disabled_x,b.enabled?b.sy:b.disabled_y,b.w,b.h},b.x,b.y);
        if(!drawn) row(p,{b.x,b.y,b.w,b.h},caption,action,b.enabled,std::min(22,std::max(10,b.h-10)));
        if(b.enabled && !action.empty()) {
            const int hx=std::max(0,b.hit_x),hy=std::max(0,b.hit_y);
            const int hw=std::min(b.w,safe_add(b.hit_x,b.hit_w))-hx;
            const int hh=std::min(b.h,safe_add(b.hit_y,b.hit_h))-hy;
            if(hw>0 && hh>0) targets.push_back({{safe_add(b.x,hx),safe_add(b.y,hy),hw,hh},action,
                b.pixels?asset:std::shared_ptr<const Texture>{},safe_add(b.hit_sx,hx-b.hit_x),safe_add(b.hit_sy,hy-b.hit_y)});
        }
    }
    void backdrop(Plane& p,scene::GameSession& game,const Config& c,const std::string& fallback) {
        if(c.number("backScriptFlag",0)!=0) return; // Host owns decorative script stepping.
        image(p,game,c.value("filenameBG",fallback),0,0);
    }
    void pagination(Plane& p,int pages) {
        const int h=std::max(24,std::min(38,height/12)),w=std::max(50,width/7);
        if(page>0) row(p,{width/2-w-6,height-h-6,w,h},U"Previous","page:prev",true,std::min(20,h-8));
        if(page+1<pages) row(p,{width/2+6,height-h-6,w,h},U"Next","page:next",true,std::min(20,h-8));
    }
    void back(Plane& p) { row(p,{8,8,std::min(100,width/4),32},U"Back","back",true,20); }
    void heading(Plane& p,std::u32string_view text) { label(p,text,std::max(118,width/5),12,std::max(18,std::min(28,width/24)),width-130); }
    void render_title(Plane& p,scene::GameSession& game) {
        const auto& c=cfg("title");
        backdrop(p,game,c,"title_bg");
        const std::array<const char*,5> actions{{"start","load","settings","extras","exit"}};
        const std::array<std::u32string,5> labels{{U"New game",U"Load game",U"Settings",U"Extras",U"Exit"}};
        const bool skinned=c.has("menu1Button1FileName") || c.has("menu1Button1PrintX") || c.has("menu1Button1PrintY");
        const int count=bound(c.number("basicButtonNumber",5),0,64);
        Button inherited;
        inherited.w=dimension(c.number("menu1Button1SizeX",16));inherited.h=dimension(c.number("menu1Button1SizeY",16));
        inherited.disabled_x=inherited.w*3;
        int x=0,y=0;
        int mode=0;
        const int modes=bound(c.number("extModeNumber",0),0,32);
        const auto variable=c.value("extModeCheckVarName");
        if(modes && !variable.empty()) mode=bound(game.named_variable(variable),0,modes);
        for(int i=0;i<count;++i) {
            if(i) { x=safe_add(x,c.number("menuNextX",0));y=safe_add(y,c.number("menuNextY",inherited.h)); }
            const auto key="menu1Button"+std::to_string(i+1);
            inherited.x=x;inherited.y=y;inherited.enabled=true;inherited.exists=true;
            inherited=button(c,key,inherited);x=inherited.x;y=inherited.y;
            Button b=inherited;
            for(int v=1;v<=mode;++v) b=button(c,"menu"+std::to_string(v+1)+"Button"+std::to_string(i+1),b);
            if(i>=5) { note("Title extension/scenario buttons require host mode dispatch and are omitted.");continue; }
            if(!skinned) {
                const int rw=std::max(120,std::min(320,width/2)),rh=std::max(28,std::min(44,height/10));
                b.x=(width-rw)/2;b.y=height/3+i*(rh+9);b.w=b.hit_w=rw;b.h=b.hit_h=rh;b.image.clear();b.pixels=false;
            }
            const auto name=c.value(key+"Name");
            draw_button(p,game,b,name.empty()?labels[i]:decode(name,true),actions[i]);
        }
        if(c.number("extButtonNumber",0)>0 || c.number("EnableHTMLButton",0)!=0 || c.number("EnableLastLoadButton",0)!=0)
            note("Title website, last-load and extension buttons have no portable action binding.");
    }
    std::string window_name(const Config& c,const std::string& prefix,const std::string& fallback,int script,int config,int font) {
        const int scripts=bound(c.number("windowNumberScript",1),1,16),settings=bound(c.number("windowNumberConfig",1),1,16);
        const int fonts=bound(c.number("windowNumberFontSizeType",1),1,std::max(1,256/(scripts*settings)));
        script=bound(script,0,scripts-1);config=bound(config,0,settings-1);font=bound(font,0,fonts-1);
        const auto suffix=scripts>1 && settings>1?std::to_string(script+1)+"_"+std::to_string(config+1):std::to_string((scripts<=1?config:script)+1);
        return c.value(prefix+suffix+(font>0?"_Font"+std::to_string(font):""),c.value(prefix,fallback));
    }
    void window(Plane& p,scene::GameSession& game,const std::string& image_name,Rect r,int bands,int opacity) {
        auto asset=texture(game,image_name);
        if(!asset) { rectangle(p,r,(static_cast<unsigned>(opacity*220/100)<<24)|0x111b2a);return; }
        if(bands&2) paint(p,*asset,{0,r.height*((bands&1)?2:1),r.width,r.height},r.x,r.y);
        paint(p,*asset,{0,0,r.width,r.height},r.x,r.y,(opacity*255+50)/100);
        if(bands&1) paint(p,*asset,{0,r.height,r.width,r.height},r.x,r.y);
    }
    void body(Plane& p,std::u32string_view source,TextLayout l,std::uint32_t tone,const Config& game_config) {
        auto parsed=markup(source,game_config.number("codeByte",2)==1);
        l.font=bound(l.font,1,128);l.space=bound(l.space,-l.font/2,128);
        l.next_x=bound(l.next_x,-width,width);l.next_y=bound(l.next_y,1,height);
        std::vector<GlyphPosition> positions;
        positions.reserve(parsed.text.size());
        int row_index=0,x=l.x,y=l.y;
        for(std::size_t i=0;i<parsed.text.size();++i) {
            const auto ch=parsed.text[i];
            if(ch==U'\r' || ch==U'\n') {
                positions.push_back({x,y,row_index});
                if(ch==U'\r' && i+1<parsed.text.size() && parsed.text[i+1]==U'\n') { ++i;positions.push_back({x,y,row_index}); }
                ++row_index;x=safe_add(l.x,row_index*l.next_x);y=safe_add(l.y,row_index*l.next_y);continue;
            }
            const int advance=std::max(1,cell_width(ch,l.font)+l.space);
            if(x>l.x && static_cast<long long>(x)+advance>width-8) {
                ++row_index;x=safe_add(l.x,row_index*l.next_x);y=safe_add(l.y,row_index*l.next_y);
            }
            positions.push_back({x,y,row_index});
            if(y<height && y+l.font>0) label(p,std::u32string_view(&parsed.text[i],1),x,y,l.font,std::max(1,width-x),tone);
            x=safe_add(x,advance);
        }
        if(game_config.number("rubiFlag",0)==0) return;
        const int ruby_size=bound(l.font*bound(game_config.number("rubiPercent",40),0,200)/100,1,128);
        const int offset=bound(game_config.number("rubiDeltaY",0),-256,256);
        for(const auto& ruby:parsed.ruby) {
            if(ruby.start>=positions.size() || ruby.end>positions.size() || ruby.text.empty()) continue;
            const auto& first=positions[ruby.start];const auto& last=positions[ruby.end-1];
            if(first.row!=last.row) {note("Ruby crossing a wrapped line is omitted.");continue;}
            const int extent=last.x-first.x+cell_width(parsed.text[ruby.end-1],l.font);
            const int label_width=static_cast<int>(ruby.text.size())*ruby_size;
            text.draw(p,ruby.text,first.x+(extent-label_width)/2,first.y-ruby_size+offset,ruby_size,std::max(extent,label_width),color(game_config,"rubiColor"));
        }
    }
    void render_dialogue(Plane& p,scene::GameSession& game) {
        const auto& frame=game.state();const auto& d=frame.dialogue;
        const auto draw=game.draw_message();
        const bool content=frame.wait==scene::Wait::Dialogue || draw==scene::DrawMessage::RetainedMessage;
        if(!content && draw!=scene::DrawMessage::Window) return;
        const auto& c=cfg("printmessage");const auto& wc=cfg("messagewindow");const auto& gc=cfg("game");
        const auto shared=game.shared_config_snapshot();
        const bool normal=d.layout_command==0x22220001U; // PRINT; LPRINT is 0x22220002.
        // Use the stable script opcode rather than assuming that window visibility implies PRINT.
        const bool windowed=d.window_visible;
        const auto visuals=game.dialogue_visuals();
        auto portraits=[&] {
            for(const auto& face:visuals.portraits) image(p,game,face.image,face.x,face.y,face.width,face.height);
        };
        if(visuals.portrait_depth==1) portraits();
        const int type=bound(d.font_type,0,bound(c.number("fontSizeTypeNumber",0),0,63));
        const auto suffix=type>0?"ByFontSizeType"+std::to_string(type):"";
        TextLayout layout;
        layout.font=c.number("fontSize"+suffix,c.number("fontSize",shared.message_font_size));
        layout.x=c.number("printX"+suffix,c.number("printX",shared.print_x));layout.y=c.number("printY"+suffix,c.number("printY",shared.print_y));
        layout.next_x=c.number("nextX"+suffix,c.number("nextX",shared.next_x));layout.next_y=c.number("nextY"+suffix,c.number("nextY",shared.next_y));
        layout.space=c.number("space"+suffix,c.number("space",1));
        if(!normal) {
            layout.x=shared.lprint_x;layout.y=shared.lprint_y;layout.next_x=shared.lnext_x;layout.next_y=shared.lnext_y;
        }
        auto decoded=decode(d.display_bytes);std::u32string name;
        const bool print_name=normal && c.number("nameFlag",1)!=0;
        if(print_name && !decoded.empty() && !visuals.cutin) {
            const auto newline=decoded.find_first_of(U"\r\n");
            if(c.number("autoNameWindowFlag",0)==0 || name_colors.find(decoded.substr(0,newline))!=name_colors.end()) {
                name=decoded.substr(0,newline);
                if(newline!=std::u32string::npos) {
                    auto at=newline+1;if(decoded[newline]==U'\r' && at<decoded.size() && decoded[at]==U'\n') ++at;
                    decoded.erase(0,at);
                } else decoded.clear();
            }
        }
        const int setting=game.runtime()?game.runtime()->message_window():0;
        const int opacity=shared.window_opacity_percent;
        if(windowed && !visuals.cutin) {
            const Rect r{wc.number("printX",0),wc.number("printY",height*2/3),dimension(wc.number("sizeX",width)),dimension(wc.number("sizeY",height/3))};
            window(p,game,window_name(wc,"filenameWindow","ta_meswin",d.window_type,setting,type),r,wc.number("notTransWindowUse",0),opacity);
            if(!name.empty() && wc.number("nameWindowFlag",0)!=0) {
                const Rect n{wc.number("namePrintX",0),wc.number("namePrintY",r.y-40),dimension(wc.number("nameSizeX",width/3)),dimension(wc.number("nameSizeY",40))};
                window(p,game,window_name(wc,"filenameNameWindow","ta_namewin",d.window_type,setting,type),n,wc.number("notTransNameWindowUse",0),opacity);
            }
        }
        if(visuals.portrait_depth==2) portraits();
        if(!content) return;
        if(!name.empty()) {
            const int font=bound(c.number("nameFontSize",20),1,128);
            int x=c.number("nameX"+suffix,c.number("nameX",layout.x-layout.next_x));
            const int y=c.number("nameY"+suffix,c.number("nameY",layout.y-layout.next_y));
            const int align=c.number("nameCenterFlag",1),columns=bound(c.number("nameLengthMax",5),0,4096);
            if(align) x=safe_add(x,std::max(0,columns-static_cast<int>(name.size()))*(shared.code_byte==1?font/2:font)/(align==1?2:1));
            const auto palette=name_colors.find(name);
            const auto tone=c.number("nameColorChangeFlag",1)!=0 && palette!=name_colors.end()?palette->second:
                (c.number("colorCustomFlag",0)!=0?color(c,"nameColor"):0xffffffff);
            label(p,name,x,y,font,std::max(1,width-x),tone);
        }
        if(visuals.cutin && !visuals.rows.empty()) {
            std::size_t start=0,index=0;
            while(start<=decoded.size()) {
                const auto end=decoded.find_first_of(U"\r\n",start);
                TextLayout row_layout=layout;
                if(index<visuals.rows.size()) {
                    const auto& r=visuals.rows[index];
                    if(r.positioned) {row_layout.x=r.x;row_layout.y=r.y;}
                    row_layout.font=bound(layout.font+r.font_delta,1,128);
                    if(r.window_type) {
                        const int rw=std::max(1,std::min(width,static_cast<int>((end==std::u32string::npos?decoded.size():end)-start)*row_layout.font+2*r.pad_x));
                        if(!image(p,game,r.window_image,r.window_x,r.window_y,rw,row_layout.font+2*r.pad_y))
                            rectangle(p,{r.window_x,r.window_y,rw,row_layout.font+2*r.pad_y},0xd0000000|r.window_color);
                    }
                }
                body(p,std::u32string_view(decoded).substr(start,end==std::u32string::npos?decoded.size()-start:end-start),row_layout,color(c,"color"),gc);
                if(end==std::u32string::npos) break;
                start=end+1;if(decoded[end]==U'\r' && start<decoded.size() && decoded[start]==U'\n') ++start;
                ++index;
            }
        } else body(p,decoded,layout,color(c,"color"),gc);
    }
    void render_choices(Plane& p,scene::GameSession& game) {
        const auto& f=game.state();if(!f.selection) return;
        const auto& s=*f.selection;const auto& c=cfg("selectmessage");
        const int count=static_cast<int>(s.options.size());if(count<=0)return;
        const bool special=s.special>0 && count<=c.number("useSpecialNumber",0);
        const int font=bound(c.number(special?"specialFontSize":"fontSize",24),8,128);
        const int cw=dimension(c.number(special?"specialCursorSizeX":"cursorSizeX",469));
        const int ch=dimension(c.number(special?"specialCursorSizeY":"cursorSizeY",27));
        const int dx=c.number(special?"specialCursorDeltaX":"cursorDeltaX",-8),dy=c.number(special?"specialCursorDeltaY":"cursorDeltaY",-2);
        int x=c.number("messagePrintX",std::min(66,width/10));
        int y=c.number("newMessagePrintY"+std::to_string(std::min(8,count)),c.number("messagePrintY",height*2/3));
        const int next_x=c.number("messageNextX",0);
        int next_y=std::max(font+4,c.number("newMessageNextY"+std::to_string(std::min(8,count)),c.number("messageNextY",30)));
        // Keep wrapped translations readable; preserve the original row spacing
        // whenever every option fits the configured line width.
        if(!special) {
            const int text_width=std::max(1,std::min(cw,width-std::max(0,x)-8));
            for(const auto& option:s.options) {
                const auto visible=markup(decode(option),cfg("game").number("codeByte",2)==1).text;
                int lines=1,advance=0;
                for(char32_t ch:visible) {
                    if(ch==U'\r')continue;
                    if(ch==U'\n'){++lines;advance=0;continue;}
                    const int cell=cell_width(ch,font)+1;
                    if(advance && advance+cell>text_width){++lines;advance=0;}
                    advance+=cell;
                }
                next_y=std::max(next_y,std::min(height,lines*(font+6)));
            }
        }
        const int captions=static_cast<int>(s.messages.size());
        const int available=std::max(1,(height-y-45)/next_y-captions);
        const int rows=bound(c.number("useScrollFlag",0)?c.number("messagePrintGyo",4)-captions:count,1,available);
        const int pages=(count+rows-1)/rows;page=bound(page,0,pages-1);
        if(!special && c.number("windowPrintFlag",1)!=0) {
            if(!image(p,game,c.value("windowFileName","ta_win_select"),c.number("windowPrintX",0),c.number("windowPrintY",height*2/3),
                dimension(c.number("windowSizeX",width)),dimension(c.number("windowSizeY",height/3))))
                rectangle(p,{0,std::max(0,y-16),width,height-std::max(0,y-16)},0xd0111b2a);
        }
        for(int i=0;i<captions;++i) {
            TextLayout l{x+i*next_x,y+i*next_y,font,0,next_y,1};
            body(p,decode(s.messages[i]),l,color(c,"messageColor"),cfg("game"));
        }
        for(int i=0;i<rows && page*rows+i<count;++i) {
            const int index=page*rows+i,row_index=captions+i;
            int mx=safe_add(x,row_index*next_x),my=safe_add(y,row_index*next_y);
            if(special) {
                const auto prefix="specialWindow"+std::to_string(count)+"print";
                const int wx=c.number(prefix+"X"+std::to_string(i+1),0),wy=c.number(prefix+"Y"+std::to_string(i+1),my);
                image(p,game,c.value("filenameSpecialWindow"),wx,wy,dimension(c.number("specialWindowSizeX",cw)),dimension(c.number("specialWindowSizeY",ch)));
                mx=safe_add(wx,c.number("specialMessagePrintX",0));my=safe_add(wy,c.number("specialMessagePrintY",0));
            }
            const Rect bounds{safe_add(mx,dx),safe_add(my,dy),std::min(cw,width-std::max(0,mx+dx)),std::max({ch,font+4,next_y-2})};
            // The cursor is a focus highlight; leave its original atlas unselected.
            rectangle(p,bounds,0x79202b3c);
            body(p,decode(s.options[index]),{mx,my,font,0,font+6,1},color(c,"messageColor"),cfg("game"));
            target(bounds,"choice:"+std::to_string(index+1));
        }
        pagination(p,pages);
        if(f.choice_limit_ms) {
            const int tw=std::min(width,dimension(c.number("timerPicSizeX",100))),th=bound(c.number("timerPicSizeY",8),1,64);
            const int tx=c.number("timerPrintX",width-tw-12),ty=c.number("timerPrintY",12);
            rectangle(p,{tx,ty,tw,th},0xa0000000);
            rectangle(p,{tx,ty,static_cast<int>(static_cast<std::uint64_t>(tw)*std::min(f.choice_remaining_ms,f.choice_limit_ms)/f.choice_limit_ms),th},0xff86d5b3);
        }
    }
    void render_menu(Plane& p,scene::GameSession& game) {
        const auto& c=cfg("systemmenu");
        rectangle(p,{0,0,width,height},0xb008101b);backdrop(p,game,c,"");
        heading(p,U"System menu");
        const std::array<const char*,8> actions{{"save","load","backlog","auto","skip","settings","extras","exit"}};
        const std::array<std::u32string,8> captions{{U"Save",U"Load",U"Backlog",U"Auto",U"Skip",U"Settings",U"Extras",U"Exit"}};
        const bool skin=c.has("menu1Button1FileName") || c.has("menu1Button1PrintX");
        // CCommonSystemMenu ordering differs between original binaries; a generic
        // menu avoids attaching the wrong action to an original unlabeled atlas.
        if(skin) note("System-menu button action order varies by game; portable labeled rows are used.");
        const int h=std::max(24,std::min(40,(height-110)/8)),w=std::max(120,std::min(340,width-40));
        for(std::size_t i=0;i<actions.size();++i) {
            bool enabled=i!=0 || game.state().wait==scene::Wait::Dialogue || game.modal_savable() || game.native_panel_can_save();
            auto caption=captions[i];
            if(i==3 && game.get_system_parameter(nnn::NNNPARAM_AUTOMODE))caption+=U"  [on]";
            if(i==4 && game.skip_active())caption+=U"  [on]";
            row(p,{(width-w)/2,56+static_cast<int>(i)*(h+4),w,h},caption,actions[i],enabled,std::min(22,h-8));
        }
        back(p);
    }
    void render_backlog(Plane& p,scene::GameSession& game) {
        rectangle(p,{0,0,width,height},0xe00c1420);
        const auto& c=cfg("backlog");image(p,game,c.value("backlogBGFileName",c.value("filenameBG","ta_backlogbg")),0,0);
        heading(p,U"Backlog");
        const int font=bound(c.number("fontSize",22),12,48),line_height=font+8;
        const int max_lines=std::max(1,(height-110)/line_height);
        const int columns=std::max(1,(width-64)/font);
        std::vector<std::u32string> lines;
        for(const auto& entry:game.backlog()) {
            auto decoded=decode(entry.text,entry.configuration_text);
            auto clean=TextRenderer::plain_dialogue(decoded);
            std::u32string line;int cells=0;
            for(char32_t ch:clean) {
                if(ch==U'\r')continue;
                const int step=ch<0x100?1:2;
                if(ch==U'\n' || cells+step>columns*2) {
                    lines.push_back(std::move(line));line.clear();cells=0;
                    if(ch==U'\n')continue;
                }
                line.push_back(ch);cells+=step;
            }
            if(!line.empty())lines.push_back(std::move(line));
            lines.emplace_back();
        }
        const int pages=std::max(1,(static_cast<int>(lines.size())+max_lines-1)/max_lines);page=bound(page,0,pages-1);
        // Page zero is the latest text. Previous/Next traverse older/newer pages.
        const int end=std::max(0,static_cast<int>(lines.size())-page*max_lines),start=std::max(0,end-max_lines);
        for(int i=start;i<end;++i)label(p,lines[i],28,56+(i-start)*line_height,font,width-56);
        if(page+1<pages)row(p,{width/2-130,height-42,120,34},U"Older","page:next",true,20);
        if(page>0)row(p,{width/2+10,height-42,120,34},U"Newer","page:prev",true,20);
        back(p);
    }
    void render_settings(Plane& p,scene::GameSession& game) {
        rectangle(p,{0,0,width,height},0xee0c1420);back(p);heading(p,U"Settings");
        struct Setting {nnn::Word id; const char32_t* name; int min,max,step;};
        const std::array<Setting,12> settings{{
            {nnn::NNNPARAM_MUSICVOLUME,U"Music volume",0,100,10},
            {nnn::NNNPARAM_SOUNDVOLUME,U"Sound volume",0,100,10},
            {nnn::NNNPARAM_VOICEVOLUME,U"Voice volume",0,100,10},
            {nnn::NNNPARAM_TOTALVOLUME,U"Master volume",0,100,10},
            {nnn::NNNPARAM_MESSAGESPEED,U"Text speed",0,4,1},
            {nnn::NNNPARAM_AUTOSPEEDSLIDER,U"Auto speed",0,100,10},
            {nnn::NNNPARAM_WINDOWPERCENT,U"Window transparency",0,100,10},
            {nnn::NNNPARAM_SKIPMODE,U"Skip unread text",0,1,1},
            {nnn::NNNPARAM_CONTINUEVOICESWITCH,U"Continue voice",0,1,1},
            {nnn::NNNPARAM_CHANGEREADMESSAGECOLORSWITCH,U"Read text color",0,1,1},
            {nnn::NNNPARAM_CHANGESELECTMESSAGECOLORSWITCH,U"Visited choice color",0,1,1},
            {nnn::NNNPARAM_AUTOCONTINUESWITCH,U"Auto continue",0,1,1}
        }};
        const int row_h=std::max(32,std::min(48,height/10)),rows=std::max(1,(height-110)/row_h);
        const int pages=(static_cast<int>(settings.size())+rows-1)/rows;page=bound(page,0,pages-1);
        const int left=std::max(12,width/12),button_w=std::max(34,std::min(54,width/10));
        for(int i=0;i<rows && page*rows+i<static_cast<int>(settings.size());++i) {
            const auto& s=settings[page*rows+i];const int value=game.get_system_parameter(s.id),y=56+i*row_h;
            rectangle(p,{left,y,width-2*left,row_h-4},0xd0213349);
            std::u32string caption=s.name;caption+=U": ";
            const auto number=std::to_string(value);caption.append(number.begin(),number.end());
            label(p,caption,left+8,y+6,std::min(22,row_h-10),std::max(1,width-2*left-2*button_w-30));
            const int x=width-left-2*button_w-8;
            row(p,{x,y,button_w,row_h-4},U"−","param:"+std::to_string(s.id)+":"+std::to_string(bound(value-s.step,s.min,s.max)),value>s.min,22);
            row(p,{x+button_w+4,y,button_w,row_h-4},U"+","param:"+std::to_string(s.id)+":"+std::to_string(bound(value+s.step,s.min,s.max)),value<s.max,22);
        }
        pagination(p,pages);
    }
    void render_slots(Plane& p,scene::GameSession& game,bool saving) {
        const auto& c=cfg(saving?"save":"load");
        rectangle(p,{0,0,width,height},0xe00c1420);backdrop(p,game,c,saving?"ta_savebg01":"ta_loadbg01");
        heading(p,saving?U"Save — select a slot":U"Load — select a slot");
        const int count=bound(bound(c.number("blockNumberX",4),1,16)*bound(c.number("blockNumberY",3),1,16)*bound(c.number("page",10),1,256),1,4096);
        const int row_h=std::max(48,std::min(100,(height-110)/3));
        const int rows=std::max(1,std::min(8,(height-110)/row_h));
        const int pages=(count+rows-1)/rows;page=bound(page,0,pages-1);
        for(int i=0;i<rows && page*rows+i<count;++i) {
            const int slot=page*rows+i+1,y=58+i*row_h,left=std::max(12,width/12),rw=width-2*left;
            const auto found=save_slots.find(slot);
            const SaveSlotInfo* info=found==save_slots.end()?nullptr:&found->second;
            const bool occupied=info && info->occupied;
            const auto number=std::to_string(slot);
            auto caption=U"Slot "+std::u32string(number.begin(),number.end());
            if(save_inventory_known)caption+=occupied?U" — Saved":U" — Empty";
            row(p,{left,y,rw,row_h-6},U"","slot:"+number,saving || !save_inventory_known || occupied,22);
            int x=left+10;
            if(occupied && info->thumbnail) {
                const int tw=std::min(rw/4,row_h),th=row_h-14;
                scaled(p,*info->thumbnail,{0,0,info->thumbnail->canvas_width,info->thumbnail->canvas_height},{x,y+4,tw,th});
                x+=tw+10;
            }
            label(p,caption,x,y+4,20,std::max(1,width-left-x-10));
            if(occupied) {
                try {
                    label(p,text.decode_utf8(info->title),x,y+28,18,std::max(1,width-left-x-10));
                    if(row_h>=76)label(p,text.decode_utf8(info->timestamp),x,y+51,16,std::max(1,width-left-x-10),0xffb7cedd);
                } catch(const std::exception& e) {note(std::string("Invalid save inventory UTF-8: ")+e.what());}
            }
        }
        pagination(p,pages);back(p);
    }
    void render_places(Plane& p,scene::GameSession& game) {
        const auto& c=cfg(game.place_mode()==nnn::RuntimeMode::SelectPlace2?"selectplace2":"selectplace");
        backdrop(p,game,c,"idou_bg");
        const auto places=game.places(),characters=game.place_characters();
        const bool positioned=c.has("place1PrintX") || c.has("place1FileName") || c.has("areaX1");
        const int fallback_rows=std::max(1,(height-110)/46);
        int visible=0;for(auto state:places)if(state)++visible;
        const int pages=positioned?1:std::max(1,(visible+fallback_rows-1)/fallback_rows);page=bound(page,0,pages-1);
        Button first;first.w=dimension(c.number("areaSizeX",160));first.h=dimension(c.number("areaSizeY",100));
        first=button(c,"place1",first);int shown=0;
        for(std::size_t i=0;i<places.size();++i) {
            if(!places[i])continue;
            if(!positioned && (shown++<page*fallback_rows || shown>(page+1)*fallback_rows))continue;
            const auto key="place"+std::to_string(i+1);
            Button b=button(c,key,first);b.enabled=places[i]==2;
            b.x=c.number(key+"PrintX",c.number("areaX"+std::to_string(i+1),b.x));
            b.y=c.number(key+"PrintY",c.number("areaY"+std::to_string(i+1),b.y));
            const auto name=c.value(key+"Name",c.value("placeAppearVarName"+std::to_string(i+1)));
            const auto number=std::to_string(i+1);
            const auto caption=name.empty()?U"Place "+std::u32string(number.begin(),number.end()):decode(name,true);
            if(!positioned) {
                row(p,{width/6,56+(shown-page*fallback_rows-1)*46,width*2/3,40},caption,"place:"+number,b.enabled,22);
            } else draw_button(p,game,b,caption,"place:"+number);
            if(c.number("charaFlag",0)!=0 && i<characters.size() && characters[i]>0 && places[i]==2) {
                const bool shared=c.number("allCharaFlag",0)!=0;
                const int w=dimension(c.number("charaSizeX",32)),h=dimension(c.number("charaSizeY",32));
                const auto name=shared?c.value("fileNameAllChara","ta_allchara"):c.value("fileNameCharaBase","ta_chara")+std::to_string(characters[i]);
                const int x=c.number("areaX"+number,b.x)+c.number("charaX"+number,c.number("charaX",0));
                const int y=c.number("areaY"+number,b.y)+c.number("charaY"+number,c.number("charaY",0));
                image(p,game,name,x,y,w,h,0,shared?(characters[i]-1)*w:0);
            }
        }
        pagination(p,pages);
    }
    void render_chart(Plane& p,scene::GameSession& game,const scene::ScriptModal& m) {
        const auto& v=*m.chart;const auto& c=cfg(game.legacy_chart()?"chart":"selectchart");
        rectangle(p,{0,0,width,height},0xf00c1420);backdrop(p,game,c,"");
        for(const auto& tile:v.tiles)image(p,game,tile.asset,0,tile.y);
        image(p,game,v.center,0,v.center_y);
        const int shift=safe_add(v.slot_y,-static_cast<long long>(v.scroll));
        const std::array<std::uint32_t,5> tones{{0xff80b4ff,0xff2463c0,0xff3e5565,0xffbfd9ff,0xff4894ff}};
        for(const auto& edge:v.roads) {
            if(edge.style<0 || edge.style>=static_cast<int>(tones.size()))continue;
            const auto suffix=std::to_string(edge.style+1);const auto base=tones[edge.style];
            const auto tone=0xff000000U | (static_cast<unsigned>(bound(c.number("lineColorR"+suffix,(base>>16)&255),0,255))<<16) |
                (static_cast<unsigned>(bound(c.number("lineColorG"+suffix,(base>>8)&255),0,255))<<8) |
                static_cast<unsigned>(bound(c.number("lineColorB"+suffix,base&255),0,255));
            road(p,safe_add(v.slot_x,edge.x1),safe_add(shift,edge.y1),safe_add(v.slot_x,edge.x2),safe_add(shift,edge.y2),tone);
        }
        const int w=bound(v.slot_width,1,4096),h=bound(v.slot_height,1,4096);
        for(const auto& node:v.nodes) {
            const int cx=safe_add(v.slot_x,node.x),cy=safe_add(shift,node.y);
            Rect r{safe_add(cx,-w/2),safe_add(cy,-h/2),w,h};
            if(static_cast<long long>(r.x)+w<=0 || r.x>=width || static_cast<long long>(r.y)+h<=0 || r.y>=height)continue;
            auto asset=texture(game,node.style<0?v.unseen:node.asset);
            bool drawn=false;
            if(asset)drawn=scaled(p,*asset,node.style<0?Rect{0,0,w,h}:Rect{node.sx,node.sy,node.sw,node.sh},r,node.access?255:130);
            if(!drawn) {
                rectangle(p,r,node.access?0xff2e5977:0xff303640);
                const auto id=std::to_string(node.id);
                label(p,U"Node "+std::u32string(id.begin(),id.end()),safe_add(r.x,5),safe_add(r.y,4),std::min(20,h),w-10);
            }
            if(node.style==3 || node.style==4) {
                image(p,game,v.current,r.x,r.y,w,h);
                rectangle(p,{r.x,r.y,w,2},0xffffd177);rectangle(p,{r.x,safe_add(r.y,h-2),w,2},0xffffd177);
            }
            const int routes=bound(node.routes,1,8);
            for(int i=0;i<routes;++i)if(node.seen&(1<<i)) {
                const int mark=std::max(2,std::min(8,w/routes));
                rectangle(p,{safe_add(r.x,i*mark),safe_add(r.y,h-4),mark-1,4},0xff8ce3a0);
            }
            if(node.access!=0 && v.pending<0) {
                // The engine validates access/route locks using these coordinates.
                // Clip to the logical viewport so packing never wraps offscreen.
                Rect hit{std::max(0,r.x),std::max(0,r.y),0,0};
                hit.width=static_cast<int>(std::min<long long>(width,static_cast<long long>(r.x)+r.width))-hit.x;
                hit.height=static_cast<int>(std::min<long long>(height,static_cast<long long>(r.y)+r.height))-hit.y;
                if(hit.width>0 && hit.height>0) {target(hit,"chart:point");chart_targets.push_back({hit});}
            }
        }
        image(p,game,v.minimap,v.mini_base_x,v.mini_base_y);
        const Rect mini{v.mini_x,v.mini_y,bound(v.mini_width,0,4096),bound(v.mini_height,0,4096)};
        if(mini.width>0 && mini.height>0) {
            rectangle(p,mini,0x90334455);
            if(v.extent>0 && v.slot_area_width>0)for(const auto& node:v.nodes) {
                const auto x=static_cast<long long>(node.x)*mini.width/v.slot_area_width;
                const auto y=static_cast<long long>(node.y)*mini.height/v.extent;
                if(x>=0 && x<mini.width && y>=0 && y<mini.height)
                    rectangle(p,{safe_add(mini.x,static_cast<int>(x)-2),safe_add(mini.y,static_cast<int>(y)-1),4,3},node.id==m.selection?0xffffd177:node.access?0xff9acbff:0xff697583);
            }
            const auto range=std::max(0LL,static_cast<long long>(v.limit)-v.min_scroll);
            const auto total=v.min_scroll==0?std::max(1LL,static_cast<long long>(v.extent)):range+height;
            const int length=bound(static_cast<int>(std::min<long long>(mini.height,static_cast<long long>(mini.height)*height/total)),1,mini.height);
            const int offset=v.min_scroll==0?static_cast<int>(static_cast<long long>(v.scroll)*mini.height/total):
                range?static_cast<int>((static_cast<long long>(v.scroll)-v.min_scroll)*(mini.height-length)/range):0;
            rectangle(p,{mini.x,safe_add(mini.y,bound(offset,0,mini.height-length)),mini.width,length},0x708ecbff);
            if(v.pending<0 && v.min_scroll<v.limit) {
                target(mini,"chart:mini");mini_targets.push_back({mini,v.min_scroll,v.limit,v.extent,v.min_scroll==0,height});
            }
        }
        // Controls are deliberately over the graph. They remain reachable even
        // when a game's original chapter/button artwork is unavailable.
        if(v.pending<0) {
            row(p,{8,8,100,32},m.return_mode?U"Return":U"Menu",m.return_mode?modal_action(0,0):"menu",true,20);
            const int step=std::max(20,height/3);
            const auto clamp_scroll=[&](long long n){return static_cast<int>(std::max<long long>(v.min_scroll,std::min<long long>(v.limit,n)));};
            row(p,{width-100,height-82,92,32},U"Up",modal_action(7,clamp_scroll(static_cast<long long>(v.scroll)-step)),v.scroll>v.min_scroll,18);
            row(p,{width-100,height-44,92,32},U"Down",modal_action(7,clamp_scroll(static_cast<long long>(v.scroll)+step)),v.scroll<v.limit,18);
            const int tabs_per_row=std::max(1,(width-128)/90),tab_rows=std::max(1,(height-100)/34);
            const int tab_page=m.page/std::max(1,tabs_per_row*tab_rows);
            const int first=tab_page*tabs_per_row*tab_rows;
            for(int i=first;i<static_cast<int>(v.page_states.size()) && i<first+tabs_per_row*tab_rows;++i) {
                const int state=v.page_states[i];if(!state)continue;
                const auto number=std::to_string(i+1);
                auto caption=(i==m.page?U"[":U"")+std::u32string(number.begin(),number.end())+(i==m.page?U"]":U"");
                if(state&4)caption+=U" *";
                const int local=i-first;
                row(p,{120+(local%tabs_per_row)*90,8+(local/tabs_per_row)*34,84,30},caption,modal_action(2,i),(state&~4)!=3 && i!=m.page,18);
            }
            if(first>0)row(p,{8,46,100,30},U"Earlier",modal_action(2,first-1),true,16);
            if(first+tabs_per_row*tab_rows<static_cast<int>(v.page_states.size()))
                row(p,{8,80,100,30},U"Later",modal_action(2,first+tabs_per_row*tab_rows),true,16);
            int y=std::max(80,height-44-static_cast<int>(std::min<std::size_t>(v.description.size(),4))*24);
            for(std::size_t i=0;i<v.description.size() && i<4;++i) {
                rectangle(p,{8,y,width-120,24},0xc00c1420);
                label(p,TextRenderer::plain_dialogue(decode(v.description[i])),16,y,18,width-144);y+=24;
            }
        } else {
            // A pending confirmation is modal: no graph, tab or menu hit leaks.
            targets.clear();chart_targets.clear();mini_targets.clear();
            rectangle(p,{0,0,width,height},0x90000000);
            const int dw=std::max(1,std::min(420,width-24)),dx=(width-dw)/2,dy=std::max(8,height/3);
            rectangle(p,{dx,dy,dw,140},0xff1b2b40);
            label(p,U"Jump to this chart node?",dx+12,dy+16,22,dw-24);
            row(p,{dx+12,dy+82,std::max(1,dw/2-18),40},U"Confirm",modal_action(4,1),true,20);
            row(p,{dx+dw/2+6,dy+82,std::max(1,dw/2-18),40},U"Cancel",modal_action(4,0),true,20);
        }
    }
    void render_text_fields(Plane& p,scene::GameSession& game,const scene::ScriptModal& m) {
        const bool name=m.mode==nnn::RuntimeMode::NameInput;
        const auto& c=cfg(name?"nameinput":"kanjiinput");
        rectangle(p,{0,0,width,height},0xee0c1420);backdrop(p,game,c,"");
        heading(p,name?U"Player name":U"Text input");
        const std::size_t fields=name?std::min<std::size_t>(2,m.text.size()):std::min<std::size_t>(1,m.text.size());
        for(std::size_t i=0;i<fields;++i) {
            const int y=72+static_cast<int>(i)*100;
            const auto key=name?(i?"name2":"name1"):"input";
            const auto title=c.value(std::string(key)+"Title");
            label(p,title.empty()?(name?(i?U"Given name":U"Surname"):U"Text"):decode(title,true),24,y,22,width-48);
            rectangle(p,{24,y+30,width-48,48},0xee213349);
            label(p,decode(m.text[i]),34,y+38,24,width-68);
        }
        label(p,U"Enter text in the host input form.",24,std::min(height-36,100+static_cast<int>(fields)*100),18,width-48,0xffb7cedd);
    }
    void render_modal(Plane& p,scene::GameSession& game) {
        const auto& m=*game.state().modal;
        if(m.chart) {render_chart(p,game,m);return;}
        if(m.mode==nnn::RuntimeMode::NameInput || m.mode==nnn::RuntimeMode::KanjiInput) {render_text_fields(p,game,m);return;}
        rectangle(p,{0,0,width,height},0xe00c1420);
        row(p,{8,8,std::min(100,width/4),32},U"Back",modal_action(0,0),true,20);
        const int mode=static_cast<int>(m.mode);
        const std::string mode_name=mode>=0 && mode<static_cast<int>(nnn::system_mode_names.size())?std::string(nnn::system_mode_names[mode]):"Native mode";
        heading(p,std::u32string(mode_name.begin(),mode_name.end()));
        int y=54;
        int groups=1;
        if(m.mode==nnn::RuntimeMode::PrintItem || m.mode==nnn::RuntimeMode::Shop)
            groups=bound(cfg(m.mode==nnn::RuntimeMode::Shop?"shop":"printitem").number("itemTypeNumber",1),1,256);
        else if(m.mode==nnn::RuntimeMode::PrintTerm)groups=bound(cfg("printterm").number("termTypeNumber",1),1,256);
        else if(m.mode==nnn::RuntimeMode::ListenVoice)groups=bound(cfg("listenvoice").number("voiceCharaNumber",1),1,256);
        if(groups>1) {
            row(p,{24,y,120,32},U"Group −",modal_action(5,m.group-1),m.group>0,18);
            row(p,{150,y,120,32},U"Group +",modal_action(5,m.group+1),m.group+1<groups,18);
            const auto number=std::to_string(m.group+1)+" / "+std::to_string(groups);
            label(p,std::u32string(number.begin(),number.end()),284,y+4,18,width-300);y+=40;
        }
        if(m.mode==nnn::RuntimeMode::Shop) {
            const auto balance=std::to_string(m.balance);
            label(p,U"Balance: "+std::u32string(balance.begin(),balance.end()),24,y,20,width-48);y+=28;
        }
        for(std::size_t i=0;i<m.text.size() && i<3;++i) {
            label(p,TextRenderer::plain_dialogue(decode(m.text[i])),24,y,20,width-48);y+=30;
        }
        const scene::ScriptModalRow* selected=nullptr;
        for(const auto& r:m.rows)if((r.flags&scene::ScriptModalRow::Selected) || r.id==m.selection){selected=&r;break;}
        if(selected && !selected->asset.empty()) {
            auto asset=texture(game,selected->asset);
            if(asset) {
                const int preview_h=std::min(120,std::max(40,height/5));
                // Keep source pixels unscaled; crop to the preview rather than
                // distort a CG or item sprite. Original gallery layouts vary.
                paint(p,*asset,{0,0,std::min(width-48,asset->canvas_width),std::min(preview_h,asset->canvas_height)},24,y);
                y+=preview_h+6;
            }
        }
        if(selected && !selected->detail.empty()) {
            label(p,TextRenderer::plain_dialogue(decode(selected->detail)),24,y,18,width-48);y+=28;
        }
        if(m.pages>1) {
            const int bx=std::max(120,width-210);
            if(m.page>0)row(p,{bx,8,90,30},U"Previous","modal:page:"+std::to_string(m.page-1),true,16);
            if(m.page+1<m.pages)row(p,{bx+96,8,90,30},U"Next","modal:page:"+std::to_string(m.page+1),true,16);
        }
        const int rows=std::max(1,(height-y-70)/52),total=static_cast<int>(m.rows.size());
        const int pages=std::max(1,(total+rows-1)/rows);page=bound(page,0,pages-1);
        for(int i=0;i<rows && page*rows+i<total;++i) {
            const auto& r=m.rows[page*rows+i];
            auto caption=TextRenderer::plain_dialogue(decode(r.label));
            if(r.flags&scene::ScriptModalRow::Locked)caption=U"[Locked] "+caption;
            if(r.flags&scene::ScriptModalRow::SoldOut)caption=U"[Sold out] "+caption;
            if(r.flags&scene::ScriptModalRow::New)caption=U"[New] "+caption;
            if(caption.empty()) {const auto id=std::to_string(r.id);caption=U"Entry "+std::u32string(id.begin(),id.end());}
            if(!r.detail.empty())caption+=U" — "+TextRenderer::plain_dialogue(decode(r.detail));
            row(p,{24,y+i*52,width-48,46},caption,"modal:"+std::to_string(r.id),(r.flags&scene::ScriptModalRow::Enabled)!=0,21);
        }
        if(m.mode==nnn::RuntimeMode::Shop && selected && m.selection>0)
            row(p,{width-170,height-44,146,34},U"Purchase",modal_action(4,m.selection),(selected->flags&scene::ScriptModalRow::PurchaseEnabled)!=0,20);
        if(m.rows.empty() && m.text.empty()) {
            label(p,U"No entries available.",24,y+12,22,width-48,0xffb7cedd);
            if(m.mode==nnn::RuntimeMode::CardSystem)
                note("Core CardSystem exposes no completion/cancel semantics; only any supplied modal rows can be presented.");
        }
        pagination(p,pages);
    }
    void controls(Plane& p,scene::GameSession& game) {
        if(!game.options_enabled())return;
        // Small portable controls remain outside the common bottom message area.
        const int w=std::max(42,std::min(80,width/9)),h=26;
        row(p,{width-3*(w+4),4,w,h},U"Menu","menu",true,16);
        row(p,{width-2*(w+4),4,w,h},U"Auto","auto",true,16);
        row(p,{width-(w+4),4,w,h},U"Skip","skip",true,16);
    }
};

Presenter::Presenter(const std::filesystem::path& root,TextRenderer& text):impl_(std::make_unique<Impl>(root,text)) {
    for(const char* name:{"title","game","printmessage","messagewindow","selectmessage","systemmenu","backlog","save","load","datafile","selectplace","selectplace2","selectchart","chart","nameinput","kanjiinput","printitem","shop","printterm","listenvoice"}) {
        Config config;
        try {
            const auto source=nnn::game_config::read(root,"init",std::string(name)+".xtx");
            std::size_t start=0;
            while(start<source.size()) {
                const auto end=source.find_first_of("\r\n",start);
                const auto line=std::string_view(source).substr(start,end==std::string::npos?source.size()-start:end-start);
                std::size_t at=0;while(at<line.size() && spacing(line[at]))++at;
                const auto begin=at;while(at<line.size() && !spacing(line[at]))++at;
                const auto key=line.substr(begin,at-begin);
                bool valid=!key.empty();
                for(char c:key)if(!((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='_'))valid=false;
                while(at<line.size() && spacing(line[at]))++at;
                if(valid && at<line.size())config.values_.emplace(lower(key),trim(line.substr(at)));
                if(end==std::string::npos)break;
                start=end+1;if(source[end]=='\r' && start<source.size() && source[start]=='\n')++start;
            }
        } catch(const std::exception& e) {impl_->note(std::string("Configuration unavailable (")+name+"): "+e.what());}
        impl_->configs.emplace(name,std::move(config));
    }
    try {
        const auto source=nnn::game_config::read(root,"spt","namecol.xtx");
        std::istringstream input(source);
        for(std::string line;std::getline(input,line);) {
            const auto decoded=impl_->decode(line);
            std::vector<std::u32string> words;std::u32string word;
            for(char32_t c:decoded) {
                if(c==U' ' || c==U'\t' || c==U'\r') {if(!word.empty()){words.push_back(std::move(word));word.clear();}}
                else word.push_back(c);
            }
            if(!word.empty())words.push_back(std::move(word));
            if(words.size()<4 || words.front().front()==U'@' || words.front().front()==U'/')continue;
            std::array<int,3> rgb{};bool valid=true;
            for(int c=0;c<3;++c) {
                std::string number;
                for(char32_t ch:words[words.size()-3+c])if(ch<128)number.push_back(static_cast<char>(ch));else valid=false;
                const auto parsed=std::from_chars(number.data(),number.data()+number.size(),rgb[c]);
                if(parsed.ec!=std::errc{} || parsed.ptr!=number.data()+number.size())valid=false;
            }
            if(!valid)continue;
            std::u32string name=words.front();
            for(std::size_t at=1;at+3<words.size();++at){name+=U' ';name+=words[at];}
            impl_->name_colors.emplace(std::move(name),0xff000000U | (static_cast<unsigned>(rgb[0]&255)<<16) |
                (static_cast<unsigned>(rgb[1]&255)<<8) | static_cast<unsigned>(rgb[2]&255));
        }
    } catch(const std::exception& e) {impl_->note(std::string("Speaker palette unavailable: ")+e.what());}
    impl_->note("Portable UI uses static normal/disabled button artwork; hover/press animation, button sounds, animated cursors and portrait lip animation are not implemented.");
}
Presenter::~Presenter()=default;
std::shared_ptr<Plane> Presenter::render(scene::GameSession& game,std::string_view overlay) {
    auto& i=*impl_;i.targets.clear();i.chart_targets.clear();i.mini_targets.clear();
    const auto dimensions=game.shared_config_snapshot();
    i.width=dimensions.screen_width;i.height=dimensions.screen_height;
    if(i.width<=0 || i.height<=0 || i.width>static_cast<int>(render::max_dimension) || i.height>static_cast<int>(render::max_dimension) ||
        static_cast<std::uint64_t>(i.width)*i.height>render::max_pixels)throw std::runtime_error("Invalid SystemNNN UI plane dimensions");
    std::string view(overlay);
    if(view.empty())view=std::to_string(static_cast<int>(game.state().wait))+":"+std::to_string(game.state().selection?game.state().selection->serial:0);
    if(overlay.empty() && game.state().modal) {
        const auto& m=*game.state().modal;
        view+=":"+std::to_string(static_cast<int>(m.mode))+":"+std::to_string(m.request)+":"+std::to_string(m.page)+":"+std::to_string(m.group);
    }
    if(view!=i.previous_view) {i.page=0;i.previous_view=view;}
    auto plane=std::make_shared<Plane>();plane->width=i.width;plane->height=i.height;plane->stride=static_cast<std::size_t>(i.width)*4;
    plane->rgba.assign(plane->stride*plane->height,0);
    // Keep native LPRINT background decoration enabled. The session paints it
    // between scene layers and this transparent plane.
    plane->show_backdrop=true;
    if(overlay=="title") i.render_title(*plane,game);
    else if(overlay=="menu") i.render_menu(*plane,game);
    else if(overlay=="backlog") i.render_backlog(*plane,game);
    else if(overlay=="settings") i.render_settings(*plane,game);
    else if(overlay=="save" || overlay=="load") i.render_slots(*plane,game,overlay=="save");
    else if(!overlay.empty()) {
        rectangle(*plane,{0,0,i.width,i.height},0xe00c1420);i.back(*plane);
        i.label(*plane,U"This panel requires a dedicated frontend.",24,64,24,i.width-48);
        i.note("Unimplemented overlay: "+std::string(overlay));
    } else {
        i.render_dialogue(*plane,game);
        if(game.state().wait==scene::Wait::Choice)i.render_choices(*plane,game);
        else if(game.state().wait==scene::Wait::Place)i.render_places(*plane,game);
        else if(game.state().modal)i.render_modal(*plane,game);
        else if(game.state().wait==scene::Wait::NativePanel) {
            const auto panel=std::to_string(game.native_panel_mode());
            const auto caption=U"Native panel "+std::u32string(panel.begin(),panel.end());
            i.label(*plane,caption,12,i.height-32,20,i.width-24);
            i.note("Native panel rendering is supplied by the session scene; host must forward logical pointer coordinates through native_panel_input.");
        }
        if(game.state().wait==scene::Wait::Error) {
            rectangle(*plane,{0,0,i.width,i.height},0xe0210d13);
            i.label(*plane,U"Script error",24,24,28,i.width-48,0xffffa8a8);
            i.label(*plane,i.decode(game.state().error),24,70,20,i.width-48);
        }
        if(!game.state().modal)i.controls(*plane,game);
    }
    return plane;
}
std::string Presenter::hit(int x,int y) const {
    if(x<0 || y<0 || x>=impl_->width || y>=impl_->height)return {};
    for(auto it=impl_->targets.rbegin();it!=impl_->targets.rend();++it) {
        const auto& r=it->rect;
        if(x<r.x || y<r.y || static_cast<long long>(x)>=static_cast<long long>(r.x)+r.width || static_cast<long long>(y)>=static_cast<long long>(r.y)+r.height)continue;
        if(it->mask && !texture_alpha(*it->mask,it->source_x+x-r.x,it->source_y+y-r.y))continue;
        if(it->action=="chart:point")return chart_point(x,y);
        if(it->action=="chart:mini") {
            for(const auto& mini:impl_->mini_targets) {
                if(mini.rect.x!=r.x || mini.rect.y!=r.y || mini.rect.width!=r.width || mini.rect.height!=r.height)continue;
                const auto range=std::max(0LL,static_cast<long long>(mini.maximum)-mini.minimum);
                const auto total=mini.legacy?std::max(1LL,static_cast<long long>(mini.extent)):range+mini.viewport;
                const auto length=std::max(1LL,std::min<long long>(r.height,static_cast<long long>(r.height)*mini.viewport/total));
                const auto travel=std::max(0LL,r.height-length);
                const auto offset=std::max(0LL,std::min(travel,static_cast<long long>(y)-r.y-length/2));
                const auto scroll=mini.legacy?offset*total/std::max(1,r.height):mini.minimum+(travel?offset*range/travel:0);
                return modal_action(7,static_cast<int>(std::max<long long>(mini.minimum,std::min<long long>(mini.maximum,scroll))));
            }
            return {};
        }
        return it->action;
    }
    return {};
}
void Presenter::set_save_slots(std::vector<SaveSlotInfo> slots) {
    impl_->save_inventory_known=true;impl_->save_slots.clear();
    for(auto& slot:slots)if(slot.slot>0 && slot.slot<=4096)impl_->save_slots.insert_or_assign(slot.slot,std::move(slot));
}
void Presenter::set_page(int value) noexcept {impl_->page=std::max(0,value);}
int Presenter::page() const noexcept {return impl_->page;}
const Config& Presenter::title_config() const noexcept {return impl_->configs.find("title")->second;}
std::string Presenter::title_background() const {
    const auto& c=title_config();return c.number("backScriptFlag",0)?std::string{}:image_key(c.value("filenameBG","title_bg"));
}
std::string Presenter::title_script() const {
    const auto& c=title_config();return c.number("backScriptFlag",0)?c.value("backScriptName"):std::string{};
}
bool Presenter::title_script_loop() const {return title_config().number("backScriptLoopFlag",0)!=0;}
const std::vector<std::string>& Presenter::diagnostics() const noexcept {return impl_->notes;}
} // namespace aether::systemnnn
