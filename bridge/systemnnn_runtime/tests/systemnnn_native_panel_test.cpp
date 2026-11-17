#include "../src/systemnnn_native_panel.h"
#include <stdexcept>
#include <vector>

namespace panel=aether::systemnnn::native_panel;
struct Session {
    struct Input {int x,y;bool click,cancel;};
    int mode=51;bool savable=true,accept_menu=true;
    std::vector<Input> inputs;std::vector<int> requests;
    int native_panel_mode() const {return mode;}
    bool native_panel_can_save() const {return savable;}
    void native_panel_input(int x,int y,bool click,bool cancel) {inputs.push_back({x,y,click,cancel});}
    bool request_native_panel_menu(int mode) {requests.push_back(mode);return accept_menu;}
};
void require(bool condition) {if(!condition)throw std::runtime_error("Native panel routing contract failed");}
int main() {
    Session s;
    panel::pointer(s,panel::Pointer::Move,0,-20,700);
    require(s.inputs.size()==1 && s.inputs.back().x==-20 && s.inputs.back().y==700 && !s.inputs.back().click);
    panel::pointer(s,panel::Pointer::Down,0,485,26);
    require(s.inputs.size()==2 && !s.inputs.back().click);
    panel::pointer(s,panel::Pointer::Up,0,485,26);
    panel::pointer(s,panel::Pointer::Move,0,700,500);
    require(s.inputs[2].click && s.inputs[2].x==485 && s.inputs[2].y==26 && !s.inputs[3].click);
    const auto before=s.inputs.size();
    panel::pointer(s,panel::Pointer::Cancel,0,485,26);
    require(s.inputs.size()==before && s.requests.empty());
    panel::pointer(s,panel::Pointer::Up,1,700,500);
    require(s.requests==std::vector<int>{13} && s.inputs.size()==before);
    s.savable=false;
    panel::back(s,700,500);
    require(s.inputs.back().cancel && !s.inputs.back().click && s.requests.size()==1);
    for(int mode:{50,52}) {s.mode=mode;s.savable=true;panel::back(s,-1,-1);require(s.inputs.back().cancel && s.requests.size()==1);}
    s.mode=51;s.accept_menu=false;
    // Refused requests remain consumed; callers must never open a fallback overlay.
    require(panel::action(s,"save",0,0) && s.requests.back()==6);
    require(panel::action(s,"load",0,0) && s.requests.back()==5);
    require(panel::action(s,"settings",0,0) && s.requests.back()==12);
    require(panel::action(s,"menu",0,0) && s.requests.back()==13);
    require(panel::action(s,"auto",0,0) && panel::action(s,"skip",0,0) && panel::action(s,"backlog",0,0));
    require(!panel::action(s,"title",0,0));
    s.requests.clear();
    for(unsigned key:{'L','S','C','M','O'})panel::key_down(s,key,10,20);
    require(s.requests==std::vector<int>({5,6,12,13,13}));
    auto input_count=s.inputs.size();
    for(unsigned key:{0x11U,0x09U,0x41U})panel::key_down(s,key,10,20);
    require(s.inputs.size()==input_count && s.requests.size()==5);
    panel::key_down(s,0x20,10,20);
    require(s.inputs.back().click && s.inputs.back().x==10 && s.inputs.back().y==20);
    require(panel::menu_overlay(5)=="load" && panel::menu_overlay(6)=="save" &&
        panel::menu_overlay(12)=="settings" && panel::menu_overlay(13)=="menu" && panel::menu_overlay(0).empty());
}
