#include "../src/systemnnn_minigame.h"
#include <algorithm>
#include <iostream>
#include <numeric>
#include <stdexcept>
using namespace aether::systemnnn::minigame;
namespace aether::systemnnn::minigame {
struct TestAccess {
    static BoardState& state(Board& b){return b.s_;}
    static bool matches(const Board& b,int a,int c){return b.matches(a,c);}
    static void check(Board& b){b.check_end();}
};
}
void require(bool ok,const char* what){if(!ok)throw std::runtime_error(what);}
void settle(Board& b){int budget=10000;while(b.animation_running()&&budget-->0)b.tick();require(budget>0,"animation did not finish");}
void clear_board(Board& b){auto& s=TestAccess::state(b);std::fill(s.cells.begin(),s.cells.end(),-1);s.stock.clear();s.waste.clear();s.animation=Animation::None;s.selected=s.held=-1;s.cleared=s.game_over=false;}
void print_vector(const std::vector<int>& values){for(int v:values)std::cout<<v<<',';std::cout<<';';}
void print_state(Board& b) {
    const auto& s=b.state();
    for(int v:{s.type,s.columns,s.rows,s.selected,s.held,s.hint_left,int(s.cleared),int(s.game_over),int(s.animation),s.frame,s.frame_limit,s.first_dealt,s.turning_card,b.hint_alpha()})std::cout<<v<<',';
    std::cout<<';';print_vector(s.cells);print_vector(s.deal_order);print_vector({s.stock.begin(),s.stock.end()});print_vector({s.waste.begin(),s.waste.end()});
    print_vector(s.moving_to);print_vector(s.erasing);print_vector(s.connection);print_vector(s.incoming);
    for(int i=0;i<int(s.cells.size());++i)std::cout<<int(b.hinted(i));
    std::cout<<';'<<b.take_sound()<<'\n';
}
void trace() {
    for(int type=1;type<=10;++type)for(unsigned seed:{0U,1U,42U,987654321U}) {
        Board b(type,seed);unsigned op=seed+123;print_state(b);
        for(int n=0;n<1200;++n) {
            op=op*1664525U+1013904223U;int which=int((op>>24)%9);
            if(which<3)b.choose(int((op>>8)%148)-3);
            else if(which==3)b.draw_stock();else if(which==4)b.show_hint();else if(which==5)b.dismiss_hint();
            else if(which==6)b.press_during_animation();else {int ticks=int((op>>8)%31);while(ticks-->0)b.tick();}
            print_state(b);
        }
    }
    // Deliberately reach rare flower/skewer/stock chains in both languages.
    for(int type=Monte;type<=Kushi;++type) {
        Board b(type,42);clear_board(b);auto& s=TestAccess::state(b);
        if(type==Monte){s.cells[2]=0;s.stock={1,2};b.draw_stock();}
        if(type==Pyramid){s.cells[42]=1;s.waste={3,4};b.draw_stock();}
        if(type==Golf){s.cells[28]=12;s.waste={0};b.choose(28);}
        if(type==Nikaku){s.cells[0]=136;s.cells[1]=137;s.cells[2]=0;s.cells[20]=1;b.choose(0);b.choose(1);}
        if(type==Kushi){s.cells[0]=0;s.cells[1]=4;s.cells[2]=1;s.cells[3]=5;b.choose(0);b.choose(2);}
        print_state(b);for(int n=0;n<200;++n){b.tick();print_state(b);}
    }
}
void rules() {
    for(int t:{Puzzle,Change}) {
        Board b(t,42);int n=t==Puzzle?9:16;
        for(int want=0;want<n;++want) {
            auto& s=TestAccess::state(b);if(s.cells[want]==want)continue;
            int from=int(std::find(s.cells.begin(),s.cells.end(),want)-s.cells.begin());require(from<int(s.cells.size()),"missing tile");
            b.choose(from);b.choose(want);if(b.state().held>=0)b.choose(from);
        }
        require(b.state().cleared,"puzzle not solvable");
    }
    {Board b(Cross,42);auto& s=TestAccess::state(b);std::fill(s.cells.begin(),s.cells.end(),0);b.choose(9);require(s.cells[9]&&s.cells[8]&&s.cells[10]&&s.cells[1]&&s.cells[17],"cross neighbors");b.choose(9);require(s.cleared,"cross inverse");}
    {Board b(Slide,42);auto& s=TestAccess::state(b);std::iota(s.cells.begin(),s.cells.end(),0);require(!b.choose(5),"slide interior accepted");for(int n=0;n<4;++n)b.choose(1);require(s.cleared,"slide rotation");}
    {Board b(Paint,42);require(!b.choose(0)&&!b.state().cleared,"paint must not award a win");}
    {Board b(Monte,42);clear_board(b);auto& s=TestAccess::state(b);s.cells[0]=0;s.cells[1]=13;require(b.choose(0)&&b.choose(1),"monte pair");settle(b);require(s.cleared,"monte clear");}
    {Board b(Monte,42);clear_board(b);auto& s=TestAccess::state(b);s.cells[2]=0;s.stock={1,2};require(b.draw_stock(),"monte compact");settle(b);require(s.cells[0]==0&&s.cells[1]==1&&s.cells[2]==2,"monte refill ordering");}
    {Board b(Pyramid,42);clear_board(b);auto& s=TestAccess::state(b);s.cells[42]=0;s.cells[43]=11;require(b.choose(42)&&b.choose(43),"pyramid thirteen");settle(b);require(s.cleared,"pyramid clear");}
    {Board b(Pyramid,42);clear_board(b);auto& s=TestAccess::state(b);s.cells[42]=12;require(b.choose(42),"pyramid king");settle(b);require(s.cleared,"king clear");}
    {Board b(Pyramid,42);clear_board(b);auto& s=TestAccess::state(b);s.cells[42]=1;s.waste={3,4};require(b.draw_stock(),"pyramid recycle");settle(b);require(s.stock==std::deque<int>({3,4}),"recycle order");require(b.draw_stock(),"draw recycled");settle(b);require(b.waste_card()==3,"recycled first");}
    {Board b(Golf,42);clear_board(b);auto& s=TestAccess::state(b);s.cells[28]=12;s.waste={0};require(b.choose(28),"golf wraparound");settle(b);require(s.cleared&&b.waste_card()==12,"golf clear");}
    {Board b(Golf,42);clear_board(b);auto& s=TestAccess::state(b);s.cells[28]=52;s.waste={6};require(b.choose(28),"golf joker");settle(b);require(s.cleared,"joker clear");}
    for(int t:{Nikaku,Kushi}) {Board b(t,42);clear_board(b);auto& s=TestAccess::state(b);s.cells[0]=0;s.cells[1]=1;require(b.choose(0)&&b.choose(1),"tile pair");settle(b);require(s.cleared,"tile clear");}
    {Board b(Nikaku,42);clear_board(b);auto& s=TestAccess::state(b);s.cells[0]=0;s.cells[17]=1;s.cells[1]=4;require(TestAccess::matches(b,0,17),"nikaku outside route");require(b.show_hint(),"hint");for(int n=0;n<29;++n)b.tick();require(b.hinted(0)&&!b.choose(0),"hint remains until dismissal");require(b.dismiss_hint()&&s.hint_left==5,"hint dismissal");}
    {Board b(Nikaku,42);clear_board(b);auto& s=TestAccess::state(b);s.cells[0]=136;s.cells[1]=137;s.cells[2]=0;s.cells[20]=1;require(b.choose(0)&&b.choose(1),"flower pair");settle(b);require(s.cells[110]==0&&s.cells[128]==1,"flower gravity");}
    {Board b(Kushi,42);clear_board(b);auto& s=TestAccess::state(b);s.cells[0]=0;s.cells[1]=4;s.cells[2]=1;s.cells[3]=5;require(b.choose(0)&&b.choose(2),"skewer span");settle(b);int group=0;for(int v:s.cells)if(v>=0&&v/4==1)++group;require(group==2,"skewer orphan returned");}
}
std::shared_ptr<Image> solid(int w,int h,unsigned color){auto p=std::make_shared<Image>();p->width=w;p->height=h;p->rgba.resize(std::size_t(w)*h*4);for(std::size_t n=0;n<p->rgba.size();n+=4){p->rgba[n]=color>>16;p->rgba[n+1]=color>>8;p->rgba[n+2]=color;p->rgba[n+3]=255;}return p;}
void frontend() {
    for(int type=1;type<=10;++type) {
        Options o;o.type=type;o.seed=42;Frontend f(o);auto before=f.render();require(before.rgba.size()==800U*600*4,"render size");
        auto ex=f.exit_area();
        f.pointer(Pointer::Down,ex.x+2,ex.y+2);f.pointer(Pointer::Up,ex.x+2,ex.y+2);require(f.take_events().exit,"exit during opening animation");
        f.tick(4000);f.pointer(Pointer::Down,ex.x+2,ex.y+2);f.pointer(Pointer::Cancel,ex.x+2,ex.y+2);f.pointer(Pointer::Up,ex.x+2,ex.y+2);require(!f.take_events().exit,"cancel exit");
        f.pointer(Pointer::Down,ex.x+2,ex.y+2);f.pointer(Pointer::Up,ex.x+2,ex.y+2);require(f.take_events().exit&&!f.take_events().exit,"exit edge");
    }
    {Options o;o.type=Change;o.seed=42;Frontend f(o);
        auto click=[&](int cell){auto r=f.cells()[cell];f.pointer(Pointer::Down,r.x+r.w/2,r.y+r.h/2);f.pointer(Pointer::Up,r.x+r.w/2,r.y+r.h/2);};
        for(int wanted=0;wanted<16;++wanted){const auto& s=f.board().state();if(s.cells[wanted]==wanted)continue;int from=int(std::find(s.cells.begin(),s.cells.end(),wanted)-s.cells.begin());click(from);click(wanted);if(f.board().state().held>=0)click(from);}
        require(f.board().state().cleared&&f.take_events().cleared&&!f.take_events().cleared,"frontend completion must be emitted once");
    }
    {Options o;o.type=Paint;o.width=128;o.height=128;Assets a;a.first=solid(128,128,0xff0000);a.second=solid(128,128,0x0000ff);Frontend f(o,a);auto before=f.render();f.pointer(Pointer::Down,32,32);f.pointer(Pointer::Move,33,32);f.pointer(Pointer::Up,33,32);auto after=f.render();require(before.rgba!=after.rgba&&!f.take_events().cleared,"paint stroke");f.pointer(Pointer::Down,32,32,1);f.pointer(Pointer::Move,33,32,1);f.pointer(Pointer::Up,33,32,1);require(f.render().rgba!=after.rgba,"paint erase");}
    {Options o;o.type=Change;Assets a;a.instructions.push_back(solid(2,2,0xff0000));Frontend f(o,a);require(f.hit(1,1)==-1,"instruction input");f.pointer(Pointer::Down,1,1);f.pointer(Pointer::Up,1,1);require(f.hit(1,1)==0,"instruction advance");}
}
int main(int argc,char**) {if(argc>1){trace();return 0;}rules();frontend();std::cout<<"minigame rules/frontend PASS\n";}
