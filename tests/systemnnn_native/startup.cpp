#include "systemnnn_startup.h"
#include "emberfall/game_session.hpp"
#include <filesystem>
#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>
using aether::systemnnn::StartupSequence;
namespace fs=std::filesystem;
void text(const fs::path& p,const std::string& t){
 fs::create_directories(p.parent_path());std::ofstream out(p,std::ios::binary);out<<t;
 if(!out)throw std::runtime_error("Cannot write startup fixture");
}
void check(bool b,const char* s){if(!b)throw std::runtime_error(s);}
struct Fixture {
 fs::path root=fs::temp_directory_path()/("aether-startup-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
 ~Fixture(){std::error_code error;fs::remove_all(root,error);}
};
int main(){try {
 Fixture fixture; const fs::path& root=fixture.root;
 const fs::path emberfall=fs::u8path(EMBERFALL_ROOT);
 fs::create_directories(root/"spt");fs::create_directories(root/"sys");
 fs::copy_file(emberfall/"core/tests/fixtures/minimal_end.spt",root/"spt/sys.spt",fs::copy_options::overwrite_existing);
 fs::copy_file(emberfall/"core/tests/fixtures/minimal_end.spt",root/"spt/open.spt",fs::copy_options::overwrite_existing);
 fs::copy_file(emberfall/"core/tests/images/fixtures/rgb24_1x1_red_p1.dwq",root/"sys/red.dwq",fs::copy_options::overwrite_existing);
 text(root/"init/game.xtx","frameTime 20\n");
 text(root/"init/nothing.xtx","nextMode 2\n");
 text(root/"init/logo.xtx","LOGONUMBER 2\nlogoNumber 8\nfilename1 RED.DWQ\nfilename2 red\ndefaultFadeInTime 2\ndefaultKeepTime 2\ndefaultFadeOutTime 2\nuseCustomSkipFlag 1\nskipOK1 0\nnextMode opening\n");
 text(root/"init/opening.xtx","filenameBG red\nenterFadeInType -1\nenterFadeInTime 2\nexitFadeOutType 1\nexitFadeOutTime 2\nnextMode printMovie\n");
 text(root/"init/printMovie.xtx","movieFileName startup.webm\nnoSkipFlag 1\nexitFadeOutColorR 31\nnextMode title\n");
 text(root/"init/title.xtx","enterFadeInType 2\nenterFadeInTime 2\nenterFadeInSkipOkFlag 0\n");
 std::string encrypted="nextMode 2\n"; for(char& c:encrypted)c=static_cast<char>(static_cast<unsigned char>(c)^255);text(root/"init2/nothing.fxf",encrypted);
 emberfall::scene::SessionOptions options;options.analyze_executable=false;options.audio.enabled=false;
 auto shared_ptr=emberfall::scene::GameSession::create_ui_preview(root,options); auto& shared=*shared_ptr;
 StartupSequence startup(root);startup.start(shared);check(startup.frame(),"no logo frame");
 check(startup.frame()->rgb[0]==255&&startup.frame()->rgb[1]==255,"logo white start");
 startup.tick(20,true);check(startup.frame()->rgb[1]>100&&startup.frame()->rgb[1]<200,"unskippable logo half fade");
 startup.tick(20,false);check(startup.frame()->rgb[0]==255&&startup.frame()->rgb[1]==0,"logo hold art");
 startup.tick(80,false);check(startup.frame()->rgb[1]==255,"second logo initial fade");
 startup.tick(0,true);check(!startup.awaiting_movie(),"opening entrance consumed skip");
 startup.tick(0,true);check(!startup.awaiting_movie(),"opening fade skip must not skip opening");
 startup.tick(0,true);check(!startup.awaiting_movie(),"opening exit must run");
 startup.tick(40,false);check(startup.awaiting_movie(),"movie not requested");
 check(startup.movie_request()->filename=="startup.webm"&&!startup.movie_request()->skippable,"movie config");
 startup.finish_movie();check(startup.awaiting_title(),"title handshake");
 auto title=*startup.frame();for(auto& b:title.rgb)b=200;
 startup.begin_title(title);check(!startup.finished(),"title fade missing");check(startup.frame()->rgb[0]==31,"movie exit capture");
 startup.tick(0,true);check(!startup.finished(),"unskippable title fade");startup.tick(40,false);check(startup.finished(),"title unfinished");
 check(startup.frame()->rgb[0]==200,"title final frame");
 text(root/"init/nothing.xtx","nextMode opening\n");
 encrypted="nextMode opening\n";for(char& c:encrypted)c=static_cast<char>(static_cast<unsigned char>(c)^255);text(root/"init2/nothing.fxf",encrypted);
 text(root/"init/opening.xtx","backScriptFlag 1\nbackScriptName open\nnextMode logo\n");
 text(root/"init/logo.xtx","nextMode opening\n");
 StartupSequence scripted(root);scripted.start(shared);scripted.tick(20,false);
 check(scripted.awaiting_title(),"script END/repeated chain not terminated");check(!scripted.warnings().empty(),"repeated mode warning absent");
 std::cout<<"PASS startup logos/order/fades/skip, opening clock/skip/END, movie request, title transition, repeated modes\n";
 return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
