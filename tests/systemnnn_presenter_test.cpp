#include "systemnnn_presenter.h"
#include "systemnnn_text.h"
#include <emberfall/game_session.hpp>
#include <algorithm>
#include <cassert>
#include <chrono>
#include <climits>
#include <filesystem>
#include <fstream>
#include <iostream>

namespace fs=std::filesystem;
namespace scene=emberfall::scene;
using aether::systemnnn::Presenter;
using aether::systemnnn::TextRenderer;
namespace {
void put(const fs::path& path,const std::string& value) {
    fs::create_directories(path.parent_path());std::ofstream out(path,std::ios::binary);
    out<<value;assert(out.good());
}
// These are presentation tests over a detached preview frame; no core execution
// follows the synthetic state. Core protocol transitions have their own tests.
scene::FrameState& frame(scene::GameSession& game) {return const_cast<scene::FrameState&>(game.state());}
std::string point(int x,int y) {return "modal:action:1:"+std::to_string((x<<16)|y);}
void premultiplied(const emberfall::render::MessagePlane& p) {
    assert(p.rgba.size()==p.stride*p.height);
    for(std::size_t i=0;i<p.rgba.size();i+=4)for(unsigned c=0;c<3;++c)assert(p.rgba[i+c]<=p.rgba[i+3]);
}
}
int main(int argc,char** argv) {
    const auto root=fs::temp_directory_path()/("systemnnn-presenter-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    fs::create_directories(root/"spt");
    struct Cleanup {fs::path p;~Cleanup(){std::error_code ec;fs::remove_all(p,ec);}} cleanup{root};
    put(root/"init/game.xtx","screenSizeX 800\nscreenSizeY 600\n");
    put(root/"init/shop.xtx","itemTypeNumber 3\n");
    TextRenderer text;if(argc>1)assert(text.load_font(fs::u8path(argv[1])));
    scene::SessionOptions opts;opts.width=800;opts.height=600;opts.audio.enabled=false;
    auto game=scene::GameSession::create_ui_preview(root,opts);
    Presenter ui(root,text);
    scene::ScriptModal modal;modal.mode=nnn::RuntimeMode::SelectChart;modal.request=7;modal.pages=4;modal.selection=1;
    auto chart=std::make_shared<scene::ChartView>();
    chart->slot_width=80;chart->slot_height=40;chart->slot_x=20;chart->slot_y=30;chart->scroll=100;
    chart->min_scroll=-200;chart->limit=1000;chart->extent=1800;chart->slot_area_width=650;
    chart->mini_x=700;chart->mini_y=90;chart->mini_width=60;chart->mini_height=300;
    chart->page_states={2,1,3,0};
    chart->nodes={{1,180,270,0,1,0,0,80,40,2,1,""},{2,380,270,5,0,0,0,80,40,1,0,""}};
    chart->roads={{180,270,380,270,0},{INT_MIN,INT_MIN,INT_MAX,INT_MAX,4}};
    modal.chart=chart;frame(*game).wait=scene::Wait::Modal;frame(*game).modal=modal;
    auto plane=ui.render(*game);premultiplied(*plane);
    assert(ui.hit(200,200)==point(200,200)); // exact logical XY, never id=1
    assert(ui.hit(205,205)==point(205,205));
    assert(ui.hit(400,200).empty()); // locked core node
    assert(ui.hit(215,20)=="modal:action:2:1");
    assert(ui.hit(305,20).empty()); // disabled chapter
    assert(ui.hit(710,20).empty()); // generic Skip control must not cover chart
    assert(ui.hit(30,20)=="menu"); // story chart cannot be dismissed as Back
    assert(ui.hit(720,530)=="modal:action:7:-100");
    assert(ui.hit(720,570)=="modal:action:7:300");
    assert(ui.hit(730,90)=="modal:action:7:-200");
    assert(ui.hit(730,389)=="modal:action:7:1000");
    assert(ui.hit(-1,0).empty() && ui.hit(800,600).empty());
    frame(*game).modal->return_mode=nnn::RuntimeMode::SelectMessage;
    ui.render(*game);assert(ui.hit(30,20)=="modal:action:0:0");
    chart->pending=2;ui.render(*game);
    assert(ui.hit(200,200).empty() && ui.hit(30,20).empty() && ui.hit(730,389).empty());
    assert(ui.hit(250,300)=="modal:action:4:1");assert(ui.hit(450,300)=="modal:action:4:0");
    chart->pending=-1;chart->scroll=chart->limit;ui.render(*game);assert(ui.hit(720,570).empty());
    chart->scroll=chart->min_scroll;ui.render(*game);assert(ui.hit(720,530).empty());
    // Whole partially clipped nodes still send the clicked visible coordinate.
    chart->scroll=100;chart->nodes[0].x=-10;ui.render(*game);assert(ui.hit(1,200)==point(1,200));
    chart->slot_y=INT_MAX;chart->scroll=INT_MIN;chart->nodes[0].y=INT_MAX;
    premultiplied(*ui.render(*game)); // overflow/offscreen metadata remains bounded

    modal.chart.reset();modal.mode=nnn::RuntimeMode::Shop;modal.pages=2;modal.group=1;modal.balance=150;
    modal.rows={{5,scene::ScriptModalRow::Enabled|scene::ScriptModalRow::PurchaseEnabled,"Potion","","50"},
        {6,scene::ScriptModalRow::Locked,"Locked","",""}};
    modal.selection=5;frame(*game).modal=modal;ui.render(*game);
    assert(ui.hit(50,65)=="modal:action:5:0" && ui.hit(180,65)=="modal:action:5:2");
    assert(ui.hit(650,570)=="modal:action:4:5");
    assert(ui.hit(40,20)=="modal:action:0:0");
    assert(ui.hit(730,20)=="modal:page:1");
    modal.mode=nnn::RuntimeMode::CardSystem;modal.selection=0;frame(*game).modal=modal;ui.render(*game);
    assert(ui.hit(50,60)=="modal:5"); // supplied rows remain functional even for extension modes
    assert(ui.hit(50,112).empty());
    modal.mode=nnn::RuntimeMode::NameInput;modal.text={"Family","Given","Fallback","Fallback2"};
    frame(*game).modal=modal;premultiplied(*ui.render(*game));assert(ui.hit(50,120).empty());

    // Host inventory distinguishes unknown, occupied and known empty load slots.
    auto unknown=ui.render(*game,"load");assert(ui.hit(100,70)=="slot:1");
    ui.set_save_slots({});ui.render(*game,"load");assert(ui.hit(100,70).empty());
    auto thumb=std::make_shared<emberfall::render::Texture>();thumb->canvas_width=2;thumb->canvas_height=2;
    thumb->pixels.width=2;thumb->pixels.height=2;thumb->pixels.rgba={255,0,0,255,255,0,0,255,255,0,0,255,255,0,0,255};
    ui.set_save_slots({{1,true,"Preview title","2026-11-17",thumb}});
    auto saved=ui.render(*game,"load");assert(ui.hit(100,70)=="slot:1");assert(ui.hit(100,170).empty());
    const auto at=70*saved->stride+80*4;assert(saved->rgba[at]==255 && saved->rgba[at+1]==0);
    premultiplied(*saved);
    ui.render(*game,"save");assert(ui.hit(100,170)=="slot:2");
    std::cout<<"SystemNNN presenter contract passed\n";
}
