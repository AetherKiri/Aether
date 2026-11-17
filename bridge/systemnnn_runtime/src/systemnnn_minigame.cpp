#include "systemnnn_minigame.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <numeric>
#include <stdexcept>
#include <utility>

namespace aether::systemnnn::minigame {
namespace {
int sign(int n) {return (n>0)-(n<0);}
int distance(int f) {return f*(f+1)/2;}
int frames_for(int d) {int f=1;while(distance(f)<d)++f;return f;}
}
Random::Random(std::uint64_t seed):seed_((seed^0x5deece66dULL)&((1ULL<<48)-1)) {}
unsigned Random::bits(int count) {seed_=(seed_*0x5deece66dULL+11)&((1ULL<<48)-1);return unsigned(seed_>>(48-count));}
int Random::next(int bound) {
    if(bound<=0)throw std::invalid_argument("Random bound must be positive");
    if((bound&-bound)==bound)return int((std::uint64_t(bound)*bits(31))>>31);
    unsigned b,v;do {b=bits(31);v=b%unsigned(bound);}while(b-v+unsigned(bound-1)>=0x80000000U);
    return int(v);
}
Board::Board(int type,std::uint64_t seed,int tw,int th):random_(seed),tile_width_(tw),tile_height_(th) {
    if(type<1||type>10||tw<1||th<1||tw>4096||th>4096)throw std::invalid_argument("Invalid minigame board");
    s_.type=type;s_.columns=type==Puzzle?3:type==Cross?8:type==Monte?6:type==Pyramid||type==Golf?7:type>=Nikaku?18:4;
    s_.rows=type==Cross||type>=Nikaku?8:type==Pyramid?7:type==Golf?5:type==Monte?4:s_.columns;
    s_.cells.assign(type==Paint?0:type==Puzzle?27:s_.columns*s_.rows,-1);
    if(type>=Monte&&type<=Golf) {
        if(type==Golf) {for(int x=0;x<s_.columns;++x)for(int y=0;y<s_.rows;++y)s_.deal_order.push_back(y*s_.columns+x);}
        else {for(int y=0;y<s_.rows;++y)for(int x=0;x<(type==Pyramid?y+1:s_.columns);++x)s_.deal_order.push_back(y*s_.columns+x);}
    }
    if(type==Puzzle||type==Change) {
        const int n=type==Puzzle?18:16;std::vector<int> v(n);std::iota(v.begin(),v.end(),0);
        for(int i=n;i>1;--i)std::swap(v[i-1],v[random_.next(i)]);
        std::copy(v.begin(),v.end(),s_.cells.begin()+(type==Puzzle?9:0));
    } else if(type==Cross) {
        std::fill(s_.cells.begin(),s_.cells.end(),0);for(int i=0;i<12;++i)reverse_cross(random_.next(int(s_.cells.size())));
    } else if(type==Slide) {
        std::iota(s_.cells.begin(),s_.cells.end(),0);constexpr int edges[]={1,2,13,14,4,8,7,11};
        for(int i=0;i<12;++i)slide(edges[random_.next(8)]);
    } else if(type>=Monte&&type<=Golf) {
        auto deck=shuffle(type==Golf?54:52,true);int at=int(deck.size());
        if(type==Golf)s_.waste.push_back(deck[--at]);
        for(int slot:s_.deal_order)s_.cells[slot]=deck[--at];
        while(at>0)s_.stock.push_back(deck[--at]);
        begin(Animation::Deal,int(s_.deal_order.size())+15);
    } else if(type>=Nikaku) {
        s_.cells=shuffle(int(s_.cells.size()),false);
        if(find_pair().empty()) {
            const int neighbor=type==Kushi?s_.columns-1:1;
            for(int i=1;i<int(s_.cells.size());++i)if(s_.cells[i]/4==s_.cells[0]/4){std::swap(s_.cells[neighbor],s_.cells[i]);break;}
        }
        begin(Animation::RevealTiles,int(s_.cells.size())+1);
    }
}
std::vector<int> Board::shuffle(int size,bool cards) {
    std::vector<int> v(size);std::iota(v.begin(),v.end(),0);
    for(int i=0;i<size;++i)std::swap(v[i],v[cards?(i+random_.next(size-1))%size:random_.next(size)]);
    return v;
}
bool Board::choose(int index) {
    if(!hint_.empty()||animation_running()||s_.cleared||s_.game_over)return false;
    if(index==waste)return s_.type==Pyramid&&!s_.waste.empty()&&pair(index);
    if(index<0||index>=int(s_.cells.size()))return false;
    switch(s_.type) {
    case Puzzle:case Change:
        if(s_.cells[index]==-1&&s_.held==-1)return false;
        std::swap(s_.cells[index],s_.held);s_.cleared=in_order(s_.type==Puzzle?9:int(s_.cells.size()));sound_="Click";return true;
    case Cross:
        reverse_cross(index);s_.cleared=std::all_of(s_.cells.begin(),s_.cells.end(),[&](int v){return v==s_.cells[0];});sound_="Click";return true;
    case Slide:
        if(!slide(index))return false;
        s_.cleared=in_order(int(s_.cells.size()));sound_="Click";return true;
    case Golf:
        if(!exposed(index)||!golf_matches(s_.cells[index]))return false;
        s_.erasing={index};begin(Animation::CollectCard,20);return true;
    case Monte:case Pyramid:case Nikaku:case Kushi:return exposed(index)&&pair(index);
    default:return false;
    }
}
bool Board::draw_stock() {
    if(animation_running()||s_.cleared||s_.game_over)return false;
    if(s_.type==Monte) {
        if(can_compact()) {
            s_.moving_to.assign(s_.cells.size(),0);int target=0;
            for(int i=0;i<int(s_.cells.size());++i)if(s_.cells[i]>=0)s_.moving_to[i]=target++;
            begin(Animation::Compact,15);
        } else if(!refill())return false;
    } else if(s_.type==Pyramid||s_.type==Golf) {
        if(s_.selected!=-1)return false;
        if(s_.stock.empty()) {
            if(s_.type!=Pyramid||redeals_==0||s_.waste.empty())return false;
            begin(Animation::Recycle,int(s_.waste.size())+10);
        } else {s_.turning_card=s_.stock.front();s_.stock.pop_front();begin(Animation::TurnCard,10);}
    } else return false;
    s_.selected=-1;sound_="Click";return true;
}
bool Board::show_hint() {
    if(s_.type<Nikaku||s_.hint_left==0||!hint_.empty()||animation_running()||s_.cleared||s_.game_over)return false;
    hint_.assign(s_.cells.size(),false);
    for(int i=0;i<int(s_.cells.size());++i)if(exposed(i))for(int j=i+1;j<int(s_.cells.size());++j)if(exposed(j)&&matches(i,j))hint_[i]=hint_[j]=true;
    hint_remaining_=29;--s_.hint_left;s_.selected=-1;return true;
}
bool Board::hinted(int i) const {return i>=0&&i<int(hint_.size())&&hint_[i];}
int Board::hint_alpha() const {return hint_.empty()||hint_remaining_%5>=3?0:(50+hint_remaining_*50/29)*255/100;}
bool Board::dismiss_hint() {if(hint_.empty())return false;hint_.clear();hint_remaining_=0;return true;}
bool Board::animation_running() const {return s_.animation!=Animation::None||hint_remaining_>0;}
std::string Board::take_sound() {return std::exchange(sound_,{});}
bool Board::press_during_animation() {
    switch(s_.animation) {
    case Animation::None:return false;
    case Animation::FallTiles:case Animation::ShiftTiles:case Animation::ReturnTiles:return true;
    case Animation::RevealTiles:case Animation::ConnectTiles:case Animation::EraseTiles:finish_animation();return true;
    default:if(s_.frame>0)finish_animation();return true;
    }
}
void Board::tick() {
    if(hint_remaining_>0){--hint_remaining_;return;}
    if(animation_running()&&++s_.frame>=s_.frame_limit)finish_animation();
}
void Board::begin(Animation next,int frames) {s_.animation=next;s_.frame=0;s_.frame_limit=frames;}
bool Board::refill() {
    if(s_.stock.empty())return false;
    int slot=0;while(slot<int(s_.cells.size())&&s_.cells[slot]>=0)++slot;s_.first_dealt=slot;
    while(slot<int(s_.cells.size())&&!s_.stock.empty()){s_.cells[slot++]=s_.stock.front();s_.stock.pop_front();}
    if(s_.first_dealt==slot)return false;
    begin(Animation::Refill,slot-s_.first_dealt+15);return true;
}
void Board::finish_animation() {
    auto phase=s_.animation;s_.animation=Animation::None;
    switch(phase) {
    case Animation::Compact:commit_moves();if(refill())s_.frame=1;else check_end();break;
    case Animation::RemoveCards:for(int i:s_.erasing)remove(i);check_end();break;
    case Animation::CollectCard:s_.waste.clear();s_.waste.push_back(s_.cells[s_.erasing[0]]);remove(s_.erasing[0]);check_end();break;
    case Animation::TurnCard:if(s_.type==Golf)s_.waste.clear();s_.waste.push_back(s_.turning_card);check_end();break;
    case Animation::Recycle:s_.stock.insert(s_.stock.end(),s_.waste.begin(),s_.waste.end());s_.waste.clear();--redeals_;break;
    case Animation::Refill:check_end();break;
    case Animation::ConnectTiles: {
        const bool flowers=s_.cells[s_.erasing[0]]/4>=34;
        for(int i:s_.erasing)s_.cells[i]=removed_tile;
        if(flowers&&!empty())begin(Animation::EraseTiles,25);else check_end();break;
    }
    case Animation::EraseTiles:if(s_.type==Kushi)erase_skewer();if(empty())check_end();else start_fall();break;
    case Animation::FallTiles:commit_moves();if(s_.type==Kushi&&has_bottom_gap())start_shift();else if(s_.type!=Kushi||!start_return())check_end();break;
    case Animation::ShiftTiles:commit_moves();if(!start_return())check_end();
        break;
    case Animation::ReturnTiles:
        for(int col=0;col<s_.columns;++col)if(s_.incoming[col]>=0)s_.cells[(empty_top_rows(col)-1)*s_.columns+col]=s_.incoming[col];
        if(!start_return())check_end();
        break;
    default:break;
    }
}
int Board::deal_progress(int ordinal) const {return std::min(15,s_.frame-(s_.animation==Animation::Refill?ordinal-s_.first_dealt:ordinal));}
bool Board::marked(int i) const {return std::find(s_.erasing.begin(),s_.erasing.end(),i)!=s_.erasing.end();}
int Board::waste_card(bool beneath) const {return s_.waste.size()<(beneath?2U:1U)?-1:s_.waste[s_.waste.size()-(beneath?2:1)];}
bool Board::in_order(int count) const {for(int i=0;i<count;++i)if(s_.cells[i]!=i)return false;return true;}
void Board::reverse_cross(int i) {
    s_.cells[i]^=1;int x=i%s_.columns,y=i/s_.columns;
    if(x>0)s_.cells[i-1]^=1;
    if(x+1<s_.columns)s_.cells[i+1]^=1;
    if(y>0)s_.cells[i-s_.columns]^=1;
    if(y+1<s_.rows)s_.cells[i+s_.columns]^=1;
}
bool Board::slide(int i) {
    int x=i%4,y=i/4,delta;
    if(x==1||x==2){if(y!=0&&y!=3)return false;delta=y==0?4:-4;}
    else {if(y==0||y==3)return false;delta=x==0?1:-1;}
    int last=s_.cells[i+3*delta];for(int n=3;n>0;--n)s_.cells[i+n*delta]=s_.cells[i+(n-1)*delta];s_.cells[i]=last;return true;
}
bool Board::exposed(int i) const {
    if(i<0||i>=int(s_.cells.size())||s_.cells[i]<0)return false;
    int next=i+s_.columns;
    if(s_.type==Pyramid)return next>=int(s_.cells.size())||(i%s_.columns<s_.columns-1&&s_.cells[next]==-1&&s_.cells[next+1]==-1);
    return s_.type!=Golf||next>=int(s_.cells.size())||s_.cells[next]==-1;
}
bool Board::golf_matches(int v) const {
    if(s_.waste.empty())return false;
    int current=s_.waste.back(),d=(v%13-current%13+13)%13;
    return v>=52||current>=52||d==1||d==12;
}
bool Board::pair(int i) {
    int v=value_at(i);
    if(s_.type==Pyramid&&v%13==12&&s_.selected==-1){s_.erasing={i};begin(Animation::RemoveCards,20);sound_="Good";return true;}
    if(s_.selected==i){s_.selected=-1;if(s_.type<Nikaku)sound_="Click";return true;}
    if(s_.selected==-1){s_.selected=i;sound_="Click";return true;}
    if(!matches(s_.selected,i)){if(s_.type<Nikaku)sound_="Bad";return false;}
    if(s_.type==Kushi) {
        int delta=sign(i%s_.columns-s_.selected%s_.columns)+s_.columns*sign(i/s_.columns-s_.selected/s_.columns);
        s_.erasing.resize((i-s_.selected)/delta+1);for(int n=0;n<int(s_.erasing.size());++n)s_.erasing[n]=s_.selected+n*delta;
        begin(Animation::EraseTiles,25);
    } else if(s_.type==Nikaku) {
        s_.erasing={s_.selected,i};s_.connection=connection_path(s_.selected,i);begin(Animation::ConnectTiles,(int(s_.connection.size())/2-1)*11);
    } else {s_.erasing={s_.selected,i};begin(Animation::RemoveCards,20);}
    s_.selected=-1;sound_="Good";return true;
}
void Board::remove(int i) {if(i==waste)s_.waste.pop_back();else s_.cells[i]=-1;}
int Board::value_at(int i) const {return i==waste?s_.waste.back():s_.cells[i];}
bool Board::matches(int first,int second) const {
    int a=value_at(first),b=value_at(second);
    if(s_.type==Pyramid)return a%13+b%13==11;
    int dx=std::abs(first%s_.columns-second%s_.columns),dy=std::abs(first/s_.columns-second/s_.columns);
    if(s_.type==Monte)return a%13==b%13&&dx<=1&&dy<=1;
    if(a/4!=b/4)return false;
    if(s_.type==Nikaku)return !connection_path(first,second).empty();
    if(dx>0&&dy>0)return dx==1&&dy==1;
    int delta=dx==0?s_.columns:1;
    for(int i=std::min(first,second)+delta;i<std::max(first,second);i+=delta)if(s_.cells[i]==-1)return false;
    return true;
}
std::vector<int> Board::connection_path(int a,int b) const {
    int x=a%s_.columns,y=a/s_.columns,u=b%s_.columns,v=b/s_.columns;
    if((x==u||y==v)&&line(x,y,u,v,a,b))return {x,y,u,v};
    if(x!=u&&y!=v){if(line(x,y,x,v,a,b)&&line(x,v,u,v,a,b))return {x,y,x,v,u,v};if(line(x,y,u,y,a,b)&&line(u,y,u,v,a,b))return {x,y,u,y,u,v};}
    for(int col=-1;col<=s_.columns;++col)if(col!=x&&col!=u&&line(x,y,col,y,a,b)&&line(col,y,col,v,a,b)&&line(col,v,u,v,a,b))return {x,y,col,y,col,v,u,v};
    for(int row=-1;row<=s_.rows;++row)if(row!=y&&row!=v&&line(x,y,x,row,a,b)&&line(x,row,u,row,a,b)&&line(u,row,u,v,a,b))return {x,y,x,row,u,row,u,v};
    return {};
}
bool Board::line(int x,int y,int u,int v,int a,int b) const {
    int dx=sign(u-x),dy=sign(v-y);
    for(;;x+=dx,y+=dy){if(x>=0&&x<s_.columns&&y>=0&&y<s_.rows){int i=y*s_.columns+x;if(i!=a&&i!=b&&s_.cells[i]>=0)return false;}if(x==u&&y==v)return true;}
}
void Board::start_fall() {
    s_.moving_to.assign(s_.cells.size(),0);int max=0;
    for(int x=0;x<s_.columns;++x){int target=s_.rows-1;for(int y=s_.rows-1;y>=0;--y){int i=y*s_.columns+x;if(s_.cells[i]<0)continue;s_.moving_to[i]=target*s_.columns+x;max=std::max(max,(target-y)*tile_height_);--target;}}
    begin(Animation::FallTiles,frames_for(max));
}
bool Board::has_bottom_gap() const {for(int i=int(s_.cells.size())-s_.columns;i+1<int(s_.cells.size());++i)if(s_.cells[i]<0&&s_.cells[i+1]>=0)return true;return false;}
void Board::start_shift() {
    s_.moving_to.assign(s_.cells.size(),0);int max=0;
    for(int y=0;y<s_.rows;++y){int target=0;for(int x=0;x<s_.columns;++x){int i=y*s_.columns+x;if(s_.cells[i]<0)continue;s_.moving_to[i]=y*s_.columns+target;max=std::max(max,(x-target)*tile_width_);++target;}}
    begin(Animation::ShiftTiles,frames_for(max));
}
void Board::commit_moves() {std::vector<int> result(s_.cells.size(),-1);for(int i=0;i<int(s_.cells.size());++i)if(s_.cells[i]>=0)result[s_.moving_to[i]]=s_.cells[i];s_.cells=std::move(result);}
void Board::erase_skewer() {
    std::vector<int> removed;
    for(int n=0;n<int(s_.erasing.size());++n){int i=s_.erasing[n];if(n+1<int(s_.erasing.size()))removed.push_back(s_.cells[i]);remove(i);}
    std::array<int,36> remaining{};for(int v:s_.cells)if(v>=0)++remaining[v/4];
    for(int group=0;group<36;++group)if(remaining[group]==1)for(int v:removed)if(v/4==group){orphan_tiles_.push_back(v);break;}
}
bool Board::start_return() {
    if(orphan_tiles_.empty())return false;
    s_.incoming.assign(s_.columns,-1);int max=0;
    while(!orphan_tiles_.empty()) {
        int start=random_.next(s_.columns),chosen=-1;
        for(int n=0;n<s_.columns;++n){int col=(start+n)%s_.columns;if(s_.cells[col]==-1&&s_.incoming[col]==-1){chosen=col;break;}}
        if(chosen<0)break;
        s_.incoming[chosen]=orphan_tiles_.front();orphan_tiles_.pop_front();max=std::max(max,empty_top_rows(chosen)*tile_height_);
    }
    if(max==0){orphan_tiles_.clear();return false;}begin(Animation::ReturnTiles,frames_for(max));return true;
}
int Board::empty_top_rows(int col) const {int row=0;while(row<s_.rows&&s_.cells[row*s_.columns+col]==-1)++row;return row;}
int Board::tile_offset(int i) const {int target=s_.moving_to[i];return std::min(s_.animation==Animation::ShiftTiles?(i%s_.columns-target%s_.columns)*tile_width_:(target/s_.columns-i/s_.columns)*tile_height_,distance(s_.frame));}
int Board::return_offset(int col) const {return std::min(empty_top_rows(col)*tile_height_,distance(s_.frame));}
std::vector<int> Board::find_pair() const {for(int i=0;i<int(s_.cells.size());++i)if(exposed(i))for(int j=i+1;j<int(s_.cells.size());++j)if(exposed(j)&&matches(i,j))return {i,j};return {};}
bool Board::empty() const {return std::none_of(s_.cells.begin(),s_.cells.end(),[](int v){return v>=0;});}
void Board::check_end() {
    s_.cleared=empty()&&(s_.type!=Monte||s_.stock.empty());if(s_.cleared)return;
    if(s_.type==Golf){if(!s_.stock.empty())return;for(int i=0;i<int(s_.cells.size());++i)if(exposed(i)&&golf_matches(s_.cells[i]))return;}
    else {
        if(s_.type==Monte&&(can_compact()||(s_.cells.back()==-1&&!s_.stock.empty())))return;
        if(s_.type==Pyramid){if(!s_.stock.empty()||(redeals_>0&&!s_.waste.empty()))return;if(!s_.waste.empty()&&s_.waste.back()%13==12)return;for(int i=0;i<int(s_.cells.size());++i)if(exposed(i)&&(s_.cells[i]%13==12||(!s_.waste.empty()&&matches(i,waste))))return;}
        if(!find_pair().empty())return;
    }
    s_.game_over=true;
}
bool Board::can_compact() const {bool gap=false;for(int v:s_.cells){if(v==-1)gap=true;else if(gap)return true;}return false;}

namespace {
bool valid(const std::shared_ptr<const Image>& i) {return i&&i->width>0&&i->height>0&&i->rgba.size()==std::size_t(i->width)*i->height*4;}
void blend(Image& dst,int x,int y,unsigned color,int opacity=100) {
    if(x<0||y<0||x>=dst.width||y>=dst.height)return;
    auto* p=dst.rgba.data()+(std::size_t(y)*dst.width+x)*4;
    unsigned a=(color>>24)*unsigned(std::clamp(opacity,0,100))/100;
    for(int n=0;n<3;++n)p[n]=std::uint8_t((((color>>(16-8*n))&255)*a+p[n]*(255-a)+127)/255);
    p[3]=255;
}
void fill(Image& dst,Rect r,unsigned color,int opacity=100) {
    if(!std::isfinite(r.x)||!std::isfinite(r.y)||!std::isfinite(r.w)||!std::isfinite(r.h))return;
    for(int y=std::max(0,int(std::floor(r.y)));y<std::min(dst.height,int(std::ceil(r.y+r.h)));++y)
        for(int x=std::max(0,int(std::floor(r.x)));x<std::min(dst.width,int(std::ceil(r.x+r.w)));++x)blend(dst,x,y,color,opacity);
}
void outline(Image& dst,Rect r,unsigned color) {fill(dst,{r.x,r.y,r.w,1},color);fill(dst,{r.x,r.y+r.h-1,r.w,1},color);fill(dst,{r.x,r.y,1,r.h},color);fill(dst,{r.x+r.w-1,r.y,1,r.h},color);}
void image(Image& dst,const Image& src,Rect part,Rect dest,int opacity=100) {
    if(src.width<1||src.height<1||src.rgba.size()!=std::size_t(src.width)*src.height*4||dest.w<=0||dest.h<=0)return;
    for(int y=std::max(0,int(std::floor(dest.y)));y<std::min(dst.height,int(std::ceil(dest.y+dest.h)));++y)
        for(int x=std::max(0,int(std::floor(dest.x)));x<std::min(dst.width,int(std::ceil(dest.x+dest.w)));++x) {
            int sx=int(part.x+(x+.5f-dest.x)*part.w/dest.w),sy=int(part.y+(y+.5f-dest.y)*part.h/dest.h);
            if(sx<0||sy<0||sx>=src.width||sy>=src.height)continue;
            const auto* p=src.rgba.data()+(std::size_t(sy)*src.width+sx)*4;
            blend(dst,x,y,(unsigned(p[3])<<24)|(unsigned(p[0])<<16)|(unsigned(p[1])<<8)|p[2],opacity);
        }
}
void full_image(Image& dst,const std::shared_ptr<const Image>& src,Rect dest) {if(valid(src))image(dst,*src,{0,0,float(src->width),float(src->height)},dest);}
// Tiny built-in digits keep fallback pieces playable without font/assets.
void digits(Image& dst,int value,Rect r,unsigned color=0xff17222c) {
    constexpr unsigned glyph[]={0x7b6f,0x2492,0x73e7,0x73cf,0x5bc9,0x79cf,0x79ef,0x7249,0x7bef,0x7bcf};
    std::string text=std::to_string(value);float scale=std::max(1.f,std::min(r.w/(text.size()*4+1),r.h/7));
    float origin=r.x+(r.w-text.size()*4*scale)/2;
    for(char c:text) {unsigned bits=glyph[c-'0'];for(int y=0;y<5;++y)for(int x=0;x<3;++x)if(bits&(1U<<(14-y*3-x)))fill(dst,{origin+x*scale,r.y+(r.h-5*scale)/2+y*scale,scale,scale},color);origin+=4*scale;}
}
}
struct Frontend::Impl {
    Options o;Assets assets;Board b;Random random;
    std::vector<Rect> cells;Rect stock,waste_rect,exit_rect;
    int card_w,card_h,hint_x=0,hint_y=0,page=0,from=-1;
    float last_x=0,last_y=0;
    bool down=false,animation_touch=false,hint_touch=false,outcome_reported=false;
    int paint_button=0,congra_x=0,congra_y=0,congra_vx=4,congra_vy=0;
    std::uint64_t remainder=0;Events events;Image painted;
    std::array<int,64*64> brush{};
    int number(std::string_view key,int fallback) const {return o.number?o.number(key,fallback):fallback;}
    int layout(std::string_view field,int fallback) const {return number("miniGame"+std::to_string(o.index+1)+std::string(field),fallback);}
    static int card_size(const Options& o,bool width) {
        const bool tiles=o.type>=Nikaku;const std::string key=std::string(tiles?"mahjong":"trump")+(width?"PicSizeX":"PicSizeY");
        int fallback=tiles?16:width?96:144;
        return std::clamp(o.number?o.number(key,fallback):fallback,1,512);
    }
    Impl(Options opts,Assets art):o(std::move(opts)),assets(std::move(art)),b(o.type,o.seed,card_size(o,true),card_size(o,false)),random(o.seed),card_w(card_size(o,true)),card_h(card_size(o,false)) {
        if(o.width<1||o.height<1||o.width>4096||o.height>4096||o.frame_ms<1||o.frame_ms>1000||o.index<0||o.index>=64)throw std::invalid_argument("Invalid minigame frontend");
        for(const auto& p:assets.instructions)if(!valid(p))throw std::invalid_argument("Invalid minigame instruction image");
        cells.resize(b.state().cells.size());layout_board();
        int w=std::clamp(number("exitSizeX",128),1,o.width),h=std::clamp(number("exitSizeY",48),1,o.height);
        exit_rect={float(number("exitPrintX"+std::to_string(o.index+1),number("exitPrintX",o.width-w-12))),float(number("exitPrintY"+std::to_string(o.index+1),number("exitPrintY",o.height-h-12))),float(w),float(h)};
    }
    void layout_board() {
        int t=o.type,cols=b.state().columns,rows=b.state().rows;
        if(t==Puzzle) {
            float w=o.width/8.f,h=o.height/8.f;
            for(int i=0;i<9;++i)cells[i]={(i%3*2+1.5f)*w,(i/3*2+1.5f)*h,w,h};
            for(int i=0;i<12;++i)cells[9+i]={(i%6+1)*w,(i<6?.25f:6.75f)*h,w,h};
            for(int i=0;i<6;++i)cells[21+i]={(i<3?.25f:6.75f)*w,(i%3*2+1.5f)*h,w,h};
            return;
        }
        if(t<=Slide) {for(int i=0;i<int(cells.size());++i)cells[i]={float(i%cols)*o.width/cols,float(i/cols)*o.height/rows,float(o.width)/cols,float(o.height)/rows};return;}
        if(t==Pyramid) {
            int gap=std::clamp((o.width-card_w*7)/7,0,card_w*3/4),dx=layout("nextX",card_w-(card_w-gap)/2),dy=layout("nextY",(o.height-16-card_h)/6);
            int x=layout("startX",o.width/2-card_w/2-6*dx),y=layout("startY",8);
            stock={float(x),float(y),float(card_w),float(card_h)};waste_rect={float(x+2*dx),float(y),float(card_w),float(card_h)};
            for(int row=0;row<rows;++row)for(int col=0;col<=row;++col)cells[row*cols+col]={float(x+dx*(2*col+6-row)),float(y+row*dy),float(card_w),float(card_h)};
            return;
        }
        int dx=card_w,dy=card_h,x=0,y=0;
        if(t==Monte){dx=layout("nextX",100);dy=layout("nextY",150);x=layout("startX",4);y=layout("startY",2);stock={float(x+7*dx),float(y),float(card_w),float(card_h)};}
        else if(t==Golf){int gap=(o.width-card_w*7)/7;dx=card_w+gap;dy=(o.height-card_h-16)/6;x=gap/2;y=8;stock={float(x+dx*4),float(y+dy*4+card_h+8),float(card_w),float(card_h)};waste_rect={float(x+dx*3),stock.y,float(card_w),float(card_h)};}
        else {x=layout("startX",0)+card_w;y=layout("startY",0)+card_h;hint_x=card_w;hint_y=o.height-card_h-16;}
        for(int i=0;i<int(cells.size());++i)cells[i]={float(x+i%cols*dx),float(y+i/cols*dy),float(card_w),float(card_h)};
    }
    int hit(float x,float y) const {
        if(page<int(assets.instructions.size()))return -1;
        if(exit_rect.contains(x,y))return -5;
        if(stock.contains(x,y))return -3;
        if(waste_rect.contains(x,y))return Board::waste;
        if(o.type>=Nikaku&&Rect{float(hint_x),float(hint_y),float(card_w*b.state().hint_left),float(card_w)}.contains(x,y))return -4;
        for(int i=int(cells.size())-1;i>=0;--i)if(cells[i].contains(x,y)&&(o.type<=Slide||b.exposed(i)))return i;
        return -1;
    }
    void sound(std::string_view name) {int se=number("miniGame"+std::string(name)+"Sound",0)-1;if(se>=0)events.sounds.push_back(se);}
    void report() {
        auto s=b.take_sound();if(!outcome_reported&&(b.state().cleared||b.state().game_over)) {
            outcome_reported=true;if(b.state().cleared){events.cleared=true;congra_x=o.width/2;congra_y=o.height/2;sound("Clear");}else {events.game_over=true;sound("Gameover");}
        } else if(!s.empty())sound(s);
    }
    void stroke(float x,float y,int button) {
        if(!valid(assets.first))return;
        if(painted.rgba.empty()) {
            painted={o.width,o.height,std::vector<std::uint8_t>(std::size_t(o.width)*o.height*4)};
            fill(painted,{0,0,float(o.width),float(o.height)},0xff004080);full_image(painted,assets.second,{0,0,float(o.width),float(o.height)});
            for(int row=0;row<64;++row)for(int col=0;col<64;++col){int dx=col-32,dy=row-32,d=int(std::sqrt((dx*dx+dy*dy)*1.5));if(d<48)brush[row*64+col]=50-d+random.next(5);}
        }
        int bx=int(x)-32,by=int(y)-32;const auto& src=button==1?assets.second:assets.first;
        for(int py=std::max(0,by);py<std::min(o.height,by+64);++py)for(int px=std::max(0,bx);px<std::min(o.width,bx+64);++px) {
            int weight=brush[(py-by)*64+px-bx];if(!weight)continue;auto* dst=painted.rgba.data()+(std::size_t(py)*o.width+px)*4;
            const std::uint8_t fallback[]={0,64,128,255};const std::uint8_t* front=fallback;
            if(valid(src)){int sx=px*src->width/o.width,sy=py*src->height/o.height;front=src->rgba.data()+(std::size_t(sy)*src->width+sx)*4;}
            for(int n=0;n<3;++n)dst[n]=std::uint8_t((front[n]*weight+dst[n]*(256-weight))>>8);
        }
    }
    void pointer(Pointer event,float x,float y,int button) {
        if(!std::isfinite(x)||!std::isfinite(y)||std::abs(x)>1000000||std::abs(y)>1000000)return;
        if(event==Pointer::Cancel){down=false;from=-1;animation_touch=hint_touch=false;return;}
        if(event==Pointer::Down) {
            down=true;paint_button=button;
            // Android exit is a sibling button; it remains usable during board animations.
            if(page==int(assets.instructions.size())&&exit_rect.contains(x,y)) {from=-5;animation_touch=hint_touch=false;return;}
            if(page==int(assets.instructions.size())&&o.type>=Nikaku) {
                hint_touch=b.dismiss_hint();if(!hint_touch&&button==2)hint_touch=b.show_hint();if(hint_touch){report();return;}
            }
            animation_touch=page==int(assets.instructions.size())&&b.press_during_animation();if(animation_touch){report();return;}
            last_x=x;last_y=y;from=hit(x,y);if(o.type==Paint&&page==int(assets.instructions.size())&&from!=-5)stroke(x,y,button);return;
        }
        if(event==Pointer::Move) {
            if(animation_touch||hint_touch)return;
            if(down&&o.type==Paint&&page==int(assets.instructions.size())&&(int(x)!=int(last_x)||int(y)!=int(last_y)))stroke(x,y,paint_button);
            last_x=x;last_y=y;return;
        }
        if(!down)return;
        down=false;
        if(animation_touch||hint_touch){animation_touch=hint_touch=false;return;}
        if(from==-5){if(exit_rect.contains(x,y))events.exit=true;from=-1;return;}
        last_x=x;last_y=y;
        if(page<int(assets.instructions.size())){++page;return;}
        const int target=hit(x,y);
        if(target==-5){if(from==-5)events.exit=true;return;}
        if(button!=0&&o.type!=Paint)return;
        if(target==-3)b.draw_stock();else if(target==Board::waste)b.choose(Board::waste);else if(target==-4)b.show_hint();
        else {if(o.type==Puzzle&&from>=0&&target>=0&&from!=target&&b.state().held<0)b.choose(from);b.choose(target);}
        report();
    }
    void piece(Image& dst,int value,Rect dest,int opacity=100) const {
        const bool tiles=o.type>=Nikaku;const auto& src=tiles?assets.mahjong:assets.trump;int col,row;
        if(tiles&&(value==144||value==145)){col=value==144?0:8;row=6;}
        else if(tiles){int group=value/4;if(group<27){col=group%9;row=group/9;if(value%4==3&&(col==2||col==4)){col=row*2+(col==4?1:0);row=5;}}else if(group<34){col=group-27;row=3;}else {col=value-136;row=4;}}
        else {col=value%13;row=value/13;if(valid(src)&&src->width<card_w*13&&!(row<4&&col<10)){if(row<3){col=row*3+col-10;row=4;}else {col=(value-49)%10;row=(value-49)/10+5;}}}
        if(valid(src)&&col>=0&&row>=0&&(col+1)*card_w<=src->width&&(row+1)*card_h<=src->height){image(dst,*src,{float(col*card_w),float(row*card_h),float(card_w),float(card_h)},dest,opacity);return;}
        fill(dst,dest,0xfff4f1e9,opacity);outline(dst,dest,0xff39414d);
        if(tiles){if(value<144)digits(dst,value/4+1,dest);else digits(dst,value==145?6:0,dest);}
        else if(value<52){digits(dst,value%13+1,dest,value/13==1||value/13==3?0xffb02020:0xff17222c);Rect suit=dest;suit.y+=dest.h*.70f;suit.h=dest.h*.25f;digits(dst,value/13+1,suit);}
        else digits(dst,value>=54?0:99,dest);
    }
    void move_piece(Image& dst,int value,Rect from,Rect to,int frame,int duration,int opacity=100) const {from.x+=int((to.x-from.x)*frame/duration);from.y+=int((to.y-from.y)*frame/duration);piece(dst,value,from,opacity);}
    void puzzle_tile(Image& dst,int value,Rect dest) const {
        auto src=assets.first;Rect part;
        if(o.type==Puzzle){int index=value%9;if(value>=9)src=assets.second;float w=o.width/8.f,h=o.height/8.f;part={(index%3*2+1.5f)*w,(index/3*2+1.5f)*h,w,h};}
        else part=cells[value];
        if(valid(src)){part.x*=float(src->width)/o.width;part.w*=float(src->width)/o.width;part.y*=float(src->height)/o.height;part.h*=float(src->height)/o.height;image(dst,*src,part,dest);}
        else {fill(dst,dest,0xff123a55);digits(dst,value+1,dest,0xffffffff);}
    }
    Image render() const;
};
Image Frontend::Impl::render() const {
    Image out{o.width,o.height,std::vector<std::uint8_t>(std::size_t(o.width)*o.height*4)};
    Rect bounds{0,0,float(o.width),float(o.height)};fill(out,bounds,0xff004080);
    if(page<int(assets.instructions.size())){full_image(out,assets.instructions[page],bounds);return out;}
    if(o.type==Paint&&!painted.rgba.empty())out=painted;
    else full_image(out,o.type==Paint?assets.second:assets.first,bounds);
    const auto& s=b.state();auto phase=s.animation;
    if(o.type<=Slide) {
        for(int i=0;i<int(cells.size());++i) {
            int value=s.cells[i];
            if(o.type==Cross){const auto& src=value==0?assets.first:assets.second;if(valid(src)){Rect part=cells[i];part.x*=float(src->width)/o.width;part.w*=float(src->width)/o.width;part.y*=float(src->height)/o.height;part.h*=float(src->height)/o.height;image(out,*src,part,cells[i]);}else if(value)fill(out,cells[i],0xa0145280);}
            else if(value<0)fill(out,cells[i],0xb0000000);else puzzle_tile(out,value,cells[i]);
            if(!s.cleared)outline(out,cells[i],0x657b94a6);
        }
        if(s.held>=0){float w=o.width/(o.type==Puzzle?8.f:4.f),h=o.height/(o.type==Puzzle?8.f:4.f);puzzle_tile(out,s.held,{last_x-w/2,last_y-h/2,w,h});}
    } else if(!s.cleared&&o.type<Nikaku) {
        bool recycle=phase==Animation::Recycle,erase=phase==Animation::RemoveCards,collect=phase==Animation::CollectCard;
        int fade=s.frame_limit?std::clamp(100*(s.frame_limit-s.frame)/s.frame_limit,1,99):100;
        piece(out,recycle||!s.stock.empty()?54:55,stock);
        if(waste_rect.w>0&&!collect){bool ew=erase&&b.marked(Board::waste);int prev=recycle?-1:b.waste_card(ew);piece(out,prev<0?55:prev,waste_rect);if(ew)piece(out,b.waste_card(),waste_rect,fade);else if(s.selected==Board::waste)fill(out,waste_rect,0x680080ff);}
        if(phase==Animation::TurnCard)move_piece(out,s.turning_card,stock,waste_rect,s.frame,s.frame_limit,30+70*s.frame/s.frame_limit);
        else if(recycle){int ordinal=0;for(int v:s.waste){int n=s.frame+ordinal++-10;if(n>=0&&n<=10)move_piece(out,v,waste_rect,stock,n,10,30+70*n/10);}}
        for(int ordinal=0;ordinal<int(s.deal_order.size());++ordinal){int i=s.deal_order[ordinal],v=s.cells[i];if(v<0||(collect&&b.marked(i)))continue;
            if(phase==Animation::Deal||(phase==Animation::Refill&&ordinal>=s.first_dealt)){int n=b.deal_progress(ordinal);if(n<0&&o.type!=Monte)continue;move_piece(out,v,stock,cells[i],std::max(0,n),15);}
            else if(phase==Animation::Compact)move_piece(out,v,cells[i],cells[s.moving_to[i]],s.frame,s.frame_limit);
            else {piece(out,v,cells[i],erase&&b.marked(i)?fade:100);if(s.selected==i)fill(out,cells[i],0x680080ff);}
        }
        if(collect){int i=s.erasing[0];move_piece(out,s.cells[i],cells[i],waste_rect,s.frame,s.frame_limit,std::min(99,50+50*(s.frame_limit-s.frame)/s.frame_limit));}
    } else if(!s.cleared&&o.type>=Nikaku) {
        if(!s.game_over)for(int i=0;i<s.hint_left;++i)piece(out,145,{float(hint_x+i*card_w),float(hint_y),float(card_w),float(card_h)});
        bool falling=phase==Animation::FallTiles,shifting=phase==Animation::ShiftTiles,erasing=phase==Animation::EraseTiles;
        for(int i=0;i<int(cells.size());++i){int v=s.cells[i];bool removed=v==Board::removed_tile;if(v<0&&(!removed||falling))continue;
            int opacity=s.game_over?40:100;Rect location=cells[i];if(removed||(phase==Animation::RevealTiles&&v>=s.frame))v=144;
            if(erasing&&(removed||(o.type==Kushi&&b.marked(i))))opacity=100*(s.frame_limit-s.frame)/s.frame_limit;
            if(falling||shifting){int n=b.tile_offset(i);location.x+=shifting?-n:0;location.y+=falling?n:0;}
            piece(out,v,location,opacity);if(s.selected==i)fill(out,location,0x680080ff);
            if(b.hint_alpha()&&b.hinted(i))fill(out,location,(unsigned(b.hint_alpha())<<24)|0xff4080);
            if(phase==Animation::ConnectTiles&&b.marked(i))fill(out,location,0x8040ffc0);
        }
        if(phase==Animation::ReturnTiles){for(int col=0;col<s.columns;++col)if(s.incoming[col]>=0){Rect r=cells[col];r.y+=b.return_offset(col)-card_h;piece(out,s.incoming[col],r);}}
        else if(phase==Animation::ConnectTiles){int active=s.frame/11,ox=int(cells[0].x)+card_w/2,oy=int(cells[0].y)+card_h/2;const auto& p=s.connection;
            for(int leg=0;leg<=active&&leg*2+3<int(p.size());++leg){int at=leg*2,n=leg<active?10:s.frame%11,x=ox+p[at]*card_w,y=oy+p[at+1]*card_h,ex=x+(p[at+2]-p[at])*card_w*n/10,ey=y+(p[at+3]-p[at+1])*card_h*n/10;fill(out,{float(std::min(x,ex)-4),float(std::min(y,ey)-4),float(std::abs(ex-x)+9),float(std::abs(ey-y)+9)},0xff40ff80);}
        }
    }
    if(s.cleared&&valid(assets.congratulations))full_image(out,assets.congratulations,{float(congra_x),float(congra_y),float(assets.congratulations->width),float(assets.congratulations->height)});
    if(valid(assets.exit))image(out,*assets.exit,{0,0,std::min(float(assets.exit->width),exit_rect.w),std::min(float(assets.exit->height),exit_rect.h)},exit_rect);
    else {fill(out,exit_rect,0xdd123a55);outline(out,exit_rect,0xffdfefff);Rect bar{exit_rect.x+exit_rect.w*.25f,exit_rect.y+exit_rect.h*.46f,exit_rect.w*.5f,exit_rect.h*.08f};fill(out,bar,0xffffffff);}
    return out;
}
Frontend::Frontend(Options options,Assets assets):impl_(std::make_unique<Impl>(std::move(options),std::move(assets))) {}
Frontend::~Frontend()=default;
Frontend::Frontend(Frontend&&) noexcept=default;
Frontend& Frontend::operator=(Frontend&&) noexcept=default;
const Board& Frontend::board() const {return impl_->b;}
const std::vector<Rect>& Frontend::cells() const {return impl_->cells;}
Rect Frontend::stock_area() const {return impl_->stock;}
Rect Frontend::waste_area() const {return impl_->waste_rect;}
Rect Frontend::exit_area() const {return impl_->exit_rect;}
int Frontend::hit(float x,float y) const {return impl_->hit(x,y);}
void Frontend::pointer(Pointer event,float x,float y,int button) {impl_->pointer(event,x,y,button);}
void Frontend::tick(std::uint32_t ms) {
    auto& i=*impl_;if(i.page<int(i.assets.instructions.size()))return;
    i.remainder+=ms;
    while(i.remainder>=unsigned(i.o.frame_ms)) {
        i.remainder-=i.o.frame_ms;i.b.tick();i.report();
        if(i.b.state().cleared&&valid(i.assets.congratulations)) {
            int max_x=std::max(0,i.o.width-i.assets.congratulations->width),max_y=std::max(0,i.o.height-i.assets.congratulations->height);
            i.congra_x+=i.congra_vx;if(i.congra_x<0){i.congra_x=0;i.congra_vx=i.random.next(10)+3;}if(i.congra_x>max_x){i.congra_x=max_x;i.congra_vx=-i.random.next(10)-3;}
            i.congra_vy+=2;i.congra_y+=i.congra_vy;if(i.congra_y<0){i.congra_y=0;i.congra_vy=1;}if(i.congra_y>max_y){i.congra_y=max_y;int speed=i.congra_vy*(70+i.random.next(30))/100;i.congra_vy=speed<10?-20-i.random.next(50):-speed;}
        }
    }
}
Image Frontend::render() const {return impl_->render();}
Events Frontend::take_events() {return std::exchange(impl_->events,{});}
} // namespace aether::systemnnn::minigame
