// Standalone test includes the binding to exercise its private parsing/conversion
// contracts. Link systemnnn_minigame.cpp and emberfall-scene (not the binding cpp).
#include "../src/systemnnn_minigame_binding.cpp"
#include <fstream>
#include <iostream>

namespace aether::systemnnn {
namespace {
void check(bool ok,const char* why){if(!ok)throw std::runtime_error(why);}
struct Temp {
    std::filesystem::path path=std::filesystem::temp_directory_path()/("aether-minigame-binding-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    Temp(){std::filesystem::create_directories(path/"spt");}
    ~Temp(){std::error_code ec;std::filesystem::remove_all(path,ec);}
};
void file(const std::filesystem::path& path,const std::string& text){std::filesystem::create_directories(path.parent_path());std::ofstream out(path,std::ios::binary);out<<text;check(bool(out),"fixture write");}
void conversion(){
    emberfall::render::Texture t;t.canvas_width=4;t.canvas_height=3;t.content={2,1,2,1};t.pixels.width=2;t.pixels.height=1;t.pixels.rgba={1,2,3,17,4,5,6,99};
    const auto image=texture_image(t,12);check(image&&image->width==4&&image->height==3,"original canvas");
    check(image->rgba[0]==0&&image->rgba[(1*4+2)*4+3]==17&&image->rgba[(1*4+3)*4]==4,"cut margins and alpha");
    check(!texture_image(t,11),"JNI pixel bound");
    t.content.x=-1;const auto clipped=texture_image(t,12);check(clipped->rgba[1*4*4]==4,"negative margin clips safely");
    check(system_key("BG_DESC.DWQ")=="sys/bg_desc","system sprite key");
    std::string cp932="ab";cp932+=char(0x81);cp932+='\\';cp932+="X.DWQ";
    check(image_key(cp932).substr(2,2)==cp932.substr(2,2),"CP932 separator trail survives");
}
void catalog(){
    Temp temp;const auto root=temp.path;
    file(root/"spt/cglist01.xtx","aa01,@aa02,*@!#12,2/[>2:8_1]aa03,ta_sys,aa01,LOCKED,bb03");
    file(root/"spt/cglist02.xtx","cc01");
    const auto words=cg_tokens("aa01,*@!#12,2/[>2:8_1]aa03,bb01");check(words.size()==3&&words[1]=="*@!#12,2/[>2:8_1]aa03","animation comma remains one row");
    std::vector<nnn::Word> keys={0x10000000,0x10000001,0x10000002,0x10000003,0x10000004,0x10000006,0x10010000};
    const auto filtered=gallery_choices(root,keys,Setup{});
    check(filtered==std::vector<std::string>({"aa/aa01","bb/bb03","cc/cc01"}),"real unlock mapping, difference/system filters and dedup");
    const auto variants=gallery_choices(root,keys,Setup("sabunOkFlag 1\n"));
    check(variants==std::vector<std::string>({"aa/aa01","aa/aa02","aa/aa03","bb/bb03","cc/cc01"}),"prefix and scroll metadata preserve unlock positions");
    check(gallery_choices(root,{},Setup("sabunOkFlag 1\nallOkFlag 1\n")).empty(),"no fabricated unlocks");
    // First missing group terminates, as Android readCg does.
    file(root/"spt/cglist04.xtx","dd01");keys.push_back(0x10030000);
    check(gallery_choices(root,keys,Setup{}).size()==3,"gap stops group scan");
    std::string encrypted="addMiniGame 2\nminiGame1 3\n";for(char& c:encrypted)c=char(static_cast<unsigned char>(c)^255U);
    file(root/"init2/minigame.fxf",encrypted);file(root/"init/minigame.xtx","addMiniGame 0\n");
    check(setup(root,"minigame").number("addMiniGame",0)==2,"encrypted init2 takes precedence");
    bool bad=false;try{cg_tokens(std::string("a\0b",3));}catch(const std::exception&){bad=true;}check(bad,"malformed CG list rejected");
}
void lifecycle(){
    Temp temp;const auto root=temp.path;
    file(root/"init/minigame.xtx","addMiniGame 2\nminiGameCheckMode1 omake\nminiGameCheckMode2 title\nexitPrintX 150\nexitPrintY 110\nexitSizeX 10\nexitSizeY 10\nminiGame1 2\nminiGame1BlockSizeX 10\nminiGame1BlockSizeY 10\nminiGame1PrintX 0\nminiGame1PrintY 0\nsetCGNumber1 1\nsetCGPlayer1_1 2\nsetCGParam1_1 3\nminiGame2 3\n");
    file(root/"init/title.xtx","miniGameFlag 1\n");file(root/"init/omake.xtx","miniGameFlag 1\n");
    emberfall::scene::SessionOptions options;options.width=160;options.height=120;options.audio.enabled=false;options.analyze_executable=false;
    auto game=Game::create_ui_preview(root,options);MiniGameBinding binding;
    bool denied=false;try{binding.start(0,*game,"title",42);}catch(const std::exception&){denied=true;}check(denied&&!binding.active(),"caller mode enforced");
    file(root/"init/omake.xtx","miniGameFlag 0\n");denied=false;try{binding.start(0,*game,"omake",42);}catch(const std::exception&){denied=true;}check(denied&&!binding.active(),"caller flag enforced");
    file(root/"init/omake.xtx","miniGameFlag 1\n");
    binding.start(0,*game,"omake",42);check(binding.active(),"start activates");
    const auto frame=binding.render();check(frame.width==160&&frame.height==120&&frame.rgb.size()==160*120*3,"render RGB provider surface");
    auto click=[&](int cell){const auto r=binding.frontend()->cells()[cell];binding.pointer(minigame::Pointer::Down,r.x+r.w/2,r.y+r.h/2);binding.pointer(minigame::Pointer::Up,r.x+r.w/2,r.y+r.h/2);};
    for(int wanted=0;wanted<16;++wanted){const auto& s=binding.frontend()->board().state();if(s.cells[wanted]==wanted)continue;const int from=static_cast<int>(std::find(s.cells.begin(),s.cells.end(),wanted)-s.cells.begin());click(from);click(wanted);if(binding.frontend()->board().state().held>=0)click(from);}
    check(binding.frontend()->board().state().cleared,"pointer-driven Change clear");
    auto result=binding.dispatch(*game);check(result.progress_changed,"real completion dispatched");
    check(game->runtime()->snapshot_gallery()==std::vector<nnn::Word>({0x10010002}),"only configured clear reward unlocked");
    check(!binding.dispatch(*game).progress_changed,"clear dispatched once");
    const auto exit=binding.frontend()->exit_area();binding.pointer(minigame::Pointer::Down,exit.x+1,exit.y+1);binding.pointer(minigame::Pointer::Up,exit.x+1,exit.y+1);result=binding.dispatch(*game);check(result.exit&&!binding.active(),"exit restores caller and deactivates");
    binding.start(1,*game,"title",42);binding.tick(5000);check(!binding.dispatch(*game).progress_changed,"Paint has no reward event");binding.stop(*game,false);
    bool invalid=false;try{binding.start(2,*game);}catch(const std::exception&){invalid=true;}check(invalid&&!binding.active(),"invalid registration stays inactive");
}
}
}
int main(){try{aether::systemnnn::conversion();aether::systemnnn::catalog();aether::systemnnn::lifecycle();std::cout<<"minigame binding PASS\n";}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
