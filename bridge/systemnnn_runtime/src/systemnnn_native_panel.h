#pragma once

#include <string_view>

namespace aether::systemnnn::native_panel {
// Call these only for the exposed story NativePanel (no preview or host overlay).
// Requests enqueue engine input; keep stepping until take_native_panel_menu()
// returns a mode. Only then open a host overlay, and resume_native_panel() when
// it closes. Session is a GameSession or a compatible test double.
enum class Pointer { Move, Down, Up, Cancel };

inline constexpr int menu_mode(std::string_view action) noexcept {
    return action=="load" ? 5 : action=="save" ? 6 :
           action=="settings" ? 12 : action=="menu" ? 13 : 0;
}
inline constexpr std::string_view menu_overlay(int mode) noexcept {
    return mode==5 ? "load" : mode==6 ? "save" :
           mode==12 ? "settings" : mode==13 ? "menu" : "";
}
template<class Session> void back(Session& game,int x,int y) {
    if(game.native_panel_mode()==51 && game.native_panel_can_save())
        game.request_native_panel_menu(13);
    else game.native_panel_input(x,y,false,true);
}
template<class Session> void pointer(Session& game,Pointer event,int button,int x,int y) {
    // Preserve off-canvas coordinates for drag hit tests. A cancelled gesture
    // must not become either a click or a panel cancel/menu command.
    if(event==Pointer::Cancel) return;
    if(event!=Pointer::Up) {game.native_panel_input(x,y,false,false);return;}
    if(button==1) back(game,x,y);
    else if(button==0) game.native_panel_input(x,y,true,false);
    else game.native_panel_input(x,y,false,false);
}
template<class Session> bool action(Session& game,std::string_view command,int x,int y) {
    if(command=="back") {back(game,x,y);return true;}
    if(const int mode=menu_mode(command)) {
        game.request_native_panel_menu(mode);return true;
    }
    // Native panels own their timing and cannot enter message modes.
    return command=="auto" || command=="skip" || command=="backlog";
}
template<class Session> void key_down(Session& game,unsigned key,int x,int y) {
    // Host key codes follow the existing provider Win32 virtual-key convention.
    // All other keys are consumed by the caller, including Ctrl/auto/skip.
    switch(key) {
    case 0x1b:back(game,x,y);break;
    case 'L':game.request_native_panel_menu(5);break;
    case 'S':game.request_native_panel_menu(6);break;
    case 'C':game.request_native_panel_menu(12);break;
    case 'M':case 'O':game.request_native_panel_menu(13);break;
    case 0x20:case 0x0d:game.native_panel_input(x,y,true,false);break;
    default:break;
    }
}
} // namespace aether::systemnnn::native_panel
