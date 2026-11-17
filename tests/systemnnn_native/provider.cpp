#include "systemnnn_runtime.h"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs=std::filesystem;
namespace {
using Word=std::uint32_t;
using Bytes=std::vector<unsigned char>;
constexpr Word control=0x66660002U,command=0x66660006U,function=0x66660007U;
constexpr int dialogue_wait=3,choice_wait=4;
void check(bool value,const std::string& message){if(!value)throw std::runtime_error(message);}
void ok(engine_result_t result,engine_handle_t handle,const char* call){
    if(result!=ENGINE_RESULT_OK){const char* error=engine_get_last_error(handle);throw std::runtime_error(std::string(call)+": "+(error?error:"unknown error"));}
}
void binary(const fs::path& file,const Bytes& value){
    fs::create_directories(file.parent_path());std::ofstream out(file,std::ios::binary|std::ios::trunc);
    out.write(reinterpret_cast<const char*>(value.data()),static_cast<std::streamsize>(value.size()));out.close();
    check(bool(out),"write fixture "+file.u8string());
}
void text(const fs::path& file,const std::string& value){binary(file,Bytes(value.begin(),value.end()));}
Bytes bytes(const fs::path& file){std::ifstream in(file,std::ios::binary);check(bool(in),"read fixture "+file.u8string());return {std::istreambuf_iterator<char>(in),std::istreambuf_iterator<char>()};}
Word le(const Bytes& value,std::size_t at){check(at+4<=value.size(),"PC word within save");return Word(value[at])|(Word(value[at+1])<<8)|(Word(value[at+2])<<16)|(Word(value[at+3])<<24);}

// Independently authored programs. The Code/Model generator in Emberfall's
// platform/scene/tests/scene_tests.cpp documents the SPT word/table encoding;
// these fixtures neither copy its scenarios nor read precompiled game scripts.
struct Script {
    std::vector<Word> code,selection_adjust,command_adjust;
    std::vector<std::string> messages{"First independent line.","Second independent line.","Selected route."};
    std::vector<std::string> strings{"Amber route","Azure route"};
    Word add(std::initializer_list<Word> words){const auto at=32U+static_cast<Word>(code.size());code.insert(code.end(),words);return at;}
    void number(Word op,std::initializer_list<Word> args){
        code.insert(code.end(),{4U+static_cast<Word>(args.size()),op==0x22220004U?command:function,op,static_cast<Word>(args.size())});
        code.insert(code.end(),args);
    }
    void color(Word r,Word g,Word b){number(0x33330013U,{0,54,0,r,g,b});}
    void draw(Word frames=1){number(0x22220004U,{frames});}
    void print(Word serial,Word message){add({6,command,0x22220001U,message,serial,0});}
    void user(Word id,std::initializer_list<Word> args={}){
        code.insert(code.end(),{4U+static_cast<Word>(args.size()),0x66660003U,id,static_cast<Word>(args.size())});
        for(Word value:args)code.push_back(0x90000000U|(value&0xffffU));
    }
    // Foreground END restarts SYS; EXIT is the actual return-to-title boundary.
    void end(){add({3,control,0x5556000bU});}
    Bytes encode()const {
        std::vector<Word> words(32,0);words[0]=32;words[1]=0x66660001U;words[2]=0x55550001U;
        words[12]=0x48545053U;words[13]=0x45444145U;words[14]=0x20203052U;words[15]=0x00202020U;
        words.insert(words.end(),code.begin(),code.end());
        const auto table=[&](Word kind,Word field,const std::vector<Word>& payload,bool record=false){
            words[field]=static_cast<Word>(words.size())+(record?0U:4U);
            words.insert(words.end(),{4U+static_cast<Word>(payload.size()),0x66660001U,0x55550002U,kind});words.insert(words.end(),payload.begin(),payload.end());
        };
        const auto string_table=[&](Word kind,Word field,const std::vector<std::string>& items){
            std::vector<Word> payload(items.size(),0);const auto base=static_cast<Word>(words.size())+4U;
            for(std::size_t i=0;i<items.size();++i){
                payload[i]=base+static_cast<Word>(payload.size());const auto start=payload.size();payload.resize(start+(items[i].size()+4)/4,0);
                for(std::size_t j=0;j<items[i].size();++j)payload[start+j/4]|=Word(static_cast<unsigned char>(items[i][j]))<<(8*(j%4));
            }
            table(kind,field,payload);
        };
        table(0x44440003U,9,{});table(0x44440003U,16,{},true);table(0x44440003U,17,{},true);
        words[4]=static_cast<Word>(messages.size());string_table(0x44440002U,5,messages);
        words[6]=static_cast<Word>(strings.size());string_table(0x44440001U,7,strings);
        table(0x44440004U,18,{});table(0x44440005U,20,{});table(0x44440006U,21,selection_adjust);
        table(0x44440007U,22,command_adjust);table(0x44440008U,23,{});
        Bytes result;for(Word word:words)for(unsigned n=0;n<4;++n)result.push_back(static_cast<unsigned char>((word^UINT32_MAX)>>(n*8)));return result;
    }
};
Script story(){
    Script s;s.color(180,30,60);s.draw();s.print(1,0);s.print(2,1);
    // Legacy SELECT: two literal labels, adjustment id 0; each CASE owns a route.
    s.selection_adjust.push_back(s.add({7,command,0x22220006U,2,0,1,0}));
    const auto route=[&](Word choice,Word r,Word g,Word b,Word serial){
        s.add({4,control,0x55560008U,choice});
        const auto block=s.add({4,control,0xa000007bU,0});
        s.color(r,g,b);s.draw();s.print(serial,2);s.end();s.add({3,control,0xa000007dU});
        s.code[block-32+3]=32U+static_cast<Word>(s.code.size())-block;
    };
    route(1,230,140,10,3);route(2,10,80,220,4);return s;
}
struct Fixture {
    fs::path root,writable;
    explicit Fixture(const fs::path& parent,const std::string& name):root(parent/fs::u8path(name)),writable(root.parent_path()/fs::u8path(name+"-writable")){
        binary(root/"SpT/SyS.SpT",story().encode());
        text(root/"init/game.xtx","frameTime 20\nextSaveDataNumber 0\n");
        // Existing fixtures test VM/input contracts with fast text; reveal fixtures
        // override this authored speed table to exercise gradual presentation.
        text(root/"init/printmessage.xtx","nameFlag 0\ncustomMessageSpeed 1\nmessageSpeed1 1000000\nmessageSpeed2 1000000\nmessageSpeed3 1000000\nmessageSpeed4 1000000\nmessageSpeed5 1000000\n");
        text(root/"init/nothing.xtx","nextMode title\n");text(root/"init/title.xtx","enterFadeType 0\n");
        text(root/"init/emberfall-system.cfg","emberfall_system 4\nfile_layer_records 32\nfile_message_width 1024\nfile_status_bytes 7088\nfile_okikae 1\nfile_system_save_version 1\nexe_analyzed 0\nsystem_save_version 1\nsystem_save_trial 0\nsystem_save_source game_files\next_start_code 100\next_block_count 1\next_block_size 6400 engine\n");
    }
    fs::path slot(unsigned n)const{return writable/"systemnnn"/("slot-"+std::to_string(n)+".sav");}
};
struct Snapshot{engine_frame_desc_t desc{};Bytes pixels;};
struct Engine {
    engine_handle_t handle=nullptr;
    explicit Engine(const Fixture& fixture){
        const auto writable=fixture.writable.u8string();engine_create_desc_t desc{};desc.struct_size=sizeof(desc);desc.api_version=ENGINE_API_VERSION;desc.writable_path_utf8=writable.c_str();
        ok(engine_create(&desc,&handle),handle,"create");
#ifdef SYSTEMNNN_TEST_FONT
        option("systemnnn.font",SYSTEMNNN_TEST_FONT);
#endif
    }
    ~Engine(){if(handle)engine_destroy(handle);}
    void destroy(){ok(engine_destroy(handle),nullptr,"destroy");handle=nullptr;}
    void option(const char* key,const std::string& value){engine_option_t o{};o.key_utf8=key;o.value_utf8=value.c_str();ok(engine_set_option(handle,&o),handle,key);}
    void action(const std::string& value){option("systemnnn.action",value);}
    void open(const Fixture& f,const char* entry=nullptr){const auto root=f.root.u8string();ok(engine_open_game(handle,root.c_str(),entry),handle,"open");}
    void tick(unsigned ms=20){ok(engine_tick(handle,ms),handle,"tick");}
    void key(unsigned value,bool down=true){engine_input_event_t e{};e.struct_size=sizeof(e);e.type=down?ENGINE_INPUT_EVENT_KEY_DOWN:ENGINE_INPUT_EVENT_KEY_UP;e.key_code=value;ok(engine_send_input(handle,&e),handle,"key input");}
    void pointer(unsigned button,double x=0,double y=0){engine_input_event_t e{};e.struct_size=sizeof(e);e.type=ENGINE_INPUT_EVENT_POINTER_UP;e.button=button;e.x=x;e.y=y;ok(engine_send_input(handle,&e),handle,"pointer input");}
    void point(uint32_t type,double x,double y,uint32_t modifiers=0){engine_input_event_t e{};e.struct_size=sizeof(e);e.type=type;e.x=x;e.y=y;e.modifiers=modifiers;ok(engine_send_input(handle,&e),handle,"minigame pointer");}
    void click(double x,double y){point(ENGINE_INPUT_EVENT_POINTER_DOWN,x,y);point(ENGINE_INPUT_EVENT_POINTER_UP,x,y);tick();}
    std::string debug(){char result[65536]{};uint32_t count=0;ok(engine_get_plugin_debug_info(handle,result,sizeof(result),&count),handle,"debug");check(count>1&&count<=sizeof(result),"debug size includes terminator");return result;}
    std::string field(const char* key){
        const auto json=debug(),needle=std::string("\"")+key+"\":";auto p=json.find(needle);check(p!=std::string::npos,"debug field "+std::string(key)+" in "+json);p+=needle.size();
        if(json[p]=='"'){const auto end=json.find('"',p+1);return json.substr(p+1,end-p-1);}const auto end=json.find_first_of(",}",p);return json.substr(p,end-p);
    }
    unsigned word(){return static_cast<unsigned>(std::stoul(field("word")));}
    int wait(){return std::stoi(field("wait"));}
    Snapshot frame(){Snapshot s;s.desc.struct_size=sizeof(s.desc);ok(engine_get_frame_desc(handle,&s.desc),handle,"describe");
        check(s.desc.width>0&&s.desc.height>0&&s.desc.stride_bytes==s.desc.width*4&&s.desc.pixel_format==ENGINE_PIXEL_FORMAT_RGBA8888,"RGBA frame dimensions and format");
        s.pixels.resize(static_cast<std::size_t>(s.desc.stride_bytes)*s.desc.height);ok(engine_read_frame_rgba(handle,s.pixels.data(),s.pixels.size()),handle,"read frame");
        for(std::size_t i=3;i<s.pixels.size();i+=4)check(s.pixels[i]==255,"opaque RGBA alpha");return s;
    }
    void until(int expected,unsigned limit=30){for(unsigned i=0;wait()!=expected&&i<limit;++i)tick();check(wait()==expected,"expected wait "+std::to_string(expected)+"; "+debug());}
    std::string form(){
        char operation[128]{},argument[16384]{};uint32_t available=0;
        ok(engine_poll_platform_request(handle,operation,sizeof(operation),argument,sizeof(argument),&available),handle,"poll form");
        check(available&&std::string(operation)=="runtime_form","native runtime_form request emitted");return argument;
    }
    static std::string form_id(const std::string& form){
        const std::string key="\"request_id\":\"";const auto begin=form.find(key);check(begin!=std::string::npos,"form has correlation id: "+form);
        const auto start=begin+key.size(),end=form.find('"',start);check(end!=std::string::npos,"terminated request id");return form.substr(start,end-start);
    }
    engine_result_t answer(const std::string& id,const std::string& first="New",const std::string& second="Given"){
        const auto response="{\"request_id\":\""+id+"\",\"result\":\"1\",\"values\":{\"field0\":\""+first+"\",\"field1\":\""+second+"\"}}";
        return engine_submit_platform_response(handle,"runtime_form",response.c_str());
    }
    void start(){key(0x0d);check(field("overlay").empty(),"Return starts new game");until(dialogue_wait);}
    void advance(){const auto original=word();for(unsigned i=0;i<4&&word()==original;++i){key(0x0d);tick();}check(word()!=original,"acknowledged dialogue advances; "+debug());}
};
void color(const Snapshot& frame,unsigned r,unsigned g,unsigned b){
    // Top-left is outside the fallback message/choice panels and text.
    check(frame.pixels.size()>=4&&frame.pixels[0]==r&&frame.pixels[1]==g&&frame.pixels[2]==b,
        "RGB effect expected "+std::to_string(r)+","+std::to_string(g)+","+std::to_string(b)+" got "+std::to_string(frame.pixels[0])+","+std::to_string(frame.pixels[1])+","+std::to_string(frame.pixels[2]));
}
engine_result_t set(Engine& e,const char* key,const char* value){engine_option_t o{};o.key_utf8=key;o.value_utf8=value;return engine_set_option(e.handle,&o);}
// Independent type-0 DWQ with sixteen uniquely colored source tiles.
Bytes puzzle_art(){
    Bytes out(118+64*64*3,0);std::fill_n(out.begin(),64,' ');out[0]='B';out[1]='M';out[2]='P';
    const std::string tag="PACKTYPE=0";std::copy(tag.begin(),tag.end(),out.begin()+48);
    const auto put=[&](std::size_t p,Word n){for(unsigned i=0;i<4;++i)out[p+i]=static_cast<unsigned char>(n>>(i*8));};
    put(36,64);put(40,64);out[64]='B';out[65]='M';put(66,static_cast<Word>(out.size()-64));put(74,54);put(78,40);put(82,64);put(86,64);out[90]=1;out[92]=24;
    for(unsigned y=0;y<64;++y)for(unsigned x=0;x<64;++x){const auto p=118+(y*64+x)*3;out[p]=static_cast<unsigned char>(20+(y/16*4+x/16)*12);out[p+1]=90;out[p+2]=130;}return out;
}
Word persisted_block_word(const Fixture& f,Word code,unsigned word){
    const auto data=bytes(f.writable/"systemnnn/sysfile.sav");for(std::size_t p=0;p+32<=data.size();){const auto size=le(data,p);check(size>=32&&size<=data.size()-p,"valid persisted block");if(le(data,p+4)==code)return le(data,p+word*4);p+=size;}throw std::runtime_error("missing persisted block");
}
Word persisted_music(const Fixture& f){
    const auto data=bytes(f.writable/"systemnnn/sysfile.sav");std::size_t p=0;
    while(p+32<=data.size()){const auto size=le(data,p);check(size>=32&&size<=data.size()-p,"valid PC block extent");if(le(data,p+4)==1)return le(data,p+44*4);p+=size;}
    throw std::runtime_error("PC SYSTEM DATA block missing");
}
}
int main(){
    const auto temporary=fs::temp_directory_path()/("aether-systemnnn-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    unsigned failures=0;
    const auto test=[&](const char* name,const std::function<void()>& run){if(const auto* filter=std::getenv("SYSTEMNNN_PROVIDER_TEST_FILTER");filter&&std::string(name).find(filter)==std::string::npos)return;try{run();std::cout<<"PASS "<<name<<'\n';}catch(const std::exception& error){++failures;std::cerr<<"FAIL "<<name<<": "<<error.what()<<'\n';}};
    try{
        ok(aether_systemnnn_register_runtime(),nullptr,"register");
        check(engine_get_runtime_provider_count()>=1,"provider inventory includes builtins");
        bool found=false;for(uint32_t i=0;i<engine_get_runtime_provider_count();++i){char id[128]{};uint32_t count=0;ok(engine_get_runtime_provider_id(i,id,sizeof(id),&count),nullptr,"provider id");found=found||std::string(id)=="systemnnn";}
        check(found,"SystemNNN registered alongside builtin KiriKiri");
        test("auto detection, mixed-case directory, title/new game, dialogue/choice and RGB",[&]{
            Fixture f(temporary,"日本語 Game");check(engine_probe_runtime_provider("systemnnn",f.root.u8string().c_str())>0,"mixed-case SPT probe");
            check(engine_probe_runtime_provider("systemnnn",temporary.u8string().c_str())==0,"unrelated directory probe");
            Engine e(f);ok(engine_set_surface_size(e.handle,1600,1200),e.handle,"surface");e.open(f);
            check(e.field("runtime")=="systemnnn"&&e.field("overlay")=="title","automatic runtime selection and title");
            char renderer[512]{};ok(engine_get_renderer_info(e.handle,renderer,sizeof(renderer)),e.handle,"renderer identity");
            check(std::string(renderer).find("SystemNNN")!=std::string::npos,"selected runtime renderer identity");
            const auto title=e.frame();e.action("start");
            check(e.field("overlay").empty()&&e.wait()==1,"new game presents DRAW before dialogue");
            color(e.frame(),180,30,60);e.until(dialogue_wait);
            const auto first=e.frame();color(first,180,30,60);check(first.pixels!=title.pixels,"new game replaces title frame");
            const auto first_word=e.word();e.tick();check(e.word()==first_word,"dialogue waits for explicit acknowledged input");
            e.advance();check(e.wait()==dialogue_wait,"second dialogue reached");e.advance();e.until(choice_wait);
            const auto choice_word=e.word();e.tick(1000);check(e.word()==choice_word&&e.wait()==choice_wait,"untimed choice waits for selection");
            e.key('2');e.tick();e.until(dialogue_wait);const auto selected=e.frame();color(selected,10,80,220);
            check(selected.desc.frame_serial>first.desc.frame_serial&&selected.pixels!=first.pixels,"CASE 2 changes RGB and frame serial");
            e.advance();for(unsigned i=0;e.field("overlay")!="title"&&i<30;++i)e.tick();
            check(e.field("overlay")=="title","script end returns to title; "+e.debug());
            e.start();e.advance();e.advance();e.until(choice_wait);e.action("choice:1");e.tick();e.until(dialogue_wait);color(e.frame(),230,140,10);
        });
        test("immutable describe/read snapshot and serial across reopen",[&]{
            Fixture f(temporary,"snapshot");Engine e(f);e.open(f);auto title=e.frame();
            check(engine_read_frame_rgba(e.handle,title.pixels.data(),title.pixels.size()-1)==ENGINE_RESULT_INVALID_ARGUMENT,"short read rejected");
            e.action("start");e.until(dialogue_wait);
            Bytes held(title.pixels.size());ok(engine_read_frame_rgba(e.handle,held.data(),held.size()),e.handle,"read held title");check(held==title.pixels,"describe snapshot survives changed live frame");
            const auto story_frame=e.frame();check(story_frame.pixels!=title.pixels&&story_frame.desc.frame_serial>title.desc.frame_serial,"new describe exposes changed frame");
            e.open(f);const auto reopened=e.frame();check(reopened.desc.frame_serial>story_frame.desc.frame_serial,"serial strictly increases across reopen");
        });
        test("PC slot save/load, overwrite and failed load/write transactions",[&]{
            Fixture f(temporary,"slots");Engine e(f);e.open(f);e.start();e.frame();const auto first_word=e.word();
            e.option("systemnnn.save_slot","3");const auto first=bytes(f.slot(3));check(first.size()>7088&&le(first,4)==0,"PC save header, not private snapshot bytes");
            e.option("systemnnn.save_slot","4");check(bytes(f.slot(4)).size()==first.size(),"second slot exported through engine API");
            e.advance();const auto second_word=e.word();check(second_word!=first_word,"different saved continuation");e.frame();e.option("systemnnn.save_slot","3");const auto second=bytes(f.slot(3));check(second!=first,"overwrite replaces slot continuation");
            e.option("systemnnn.load_slot","3");check(e.word()==second_word&&e.wait()==dialogue_wait,"load overwritten continuation");
            e.option("systemnnn.load_slot","4");check(e.word()==first_word,"independent slot restores earlier continuation");
            const auto before=e.frame();binary(f.slot(5),Bytes{1,2,3});
            check(set(e,"systemnnn.load_slot","5")!=ENGINE_RESULT_OK,"truncated slot rejected");check(e.word()==first_word&&e.wait()==dialogue_wait,"failed load retains VM continuation");check(e.frame().pixels==before.pixels,"failed load retains rendered frame");
            check(set(e,"systemnnn.load_slot","999")!=ENGINE_RESULT_OK,"missing slot rejected");check(e.word()==first_word,"missing slot retains VM");
            check(set(e,"systemnnn.save_slot","1000")!=ENGINE_RESULT_OK,"out-of-range save rejected");
            // Block the staging filename: failure must preserve the existing slot exactly.
            fs::create_directory(fs::path(f.slot(3).u8string()+".tmp"));
            check(set(e,"systemnnn.save_slot","3")!=ENGINE_RESULT_OK,"blocked staging write rejected");check(bytes(f.slot(3))==second,"failed overwrite retains old slot bytes");
            e.option("systemnnn.load_slot","3");check(e.word()==second_word,"valid load recovers after rejected transactions");
        });
        test("settings action, PC persistence, reopen and fresh handle",[&]{
            Fixture f(temporary,"settings");Engine e(f);e.open(f);e.action("settings");check(e.field("overlay")=="settings","settings overlay");
            e.action("param:100:30");ok(engine_pause(e.handle),e.handle,"persist settings");check(persisted_music(f)==30,"settings writes original PC music volume field");ok(engine_resume(e.handle),e.handle,"resume");
            e.open(f);e.action("settings");const auto thirty=e.frame();e.action("param:100:70");check(e.frame().pixels!=thirty.pixels,"settings value changes visible caption");
            e.action("param:100:30");check(e.frame().pixels==thirty.pixels,"reopened settings retains saved value");
            // Click Music volume + using the authored fallback settings geometry.
            const int left=static_cast<int>(thirty.desc.width)/12,button=std::max(34,std::min(54,static_cast<int>(thirty.desc.width)/10));
            e.pointer(0,thirty.desc.width-left-button,64);ok(engine_pause(e.handle),e.handle,"persist clicked setting");check(persisted_music(f)==40,"settings pointer applies one increment");ok(engine_resume(e.handle),e.handle,"resume");
            e.destroy();Engine fresh(f);fresh.open(f);fresh.action("settings");const auto restored=fresh.frame();fresh.action("param:100:40");check(fresh.frame().pixels==restored.pixels,"fresh handle loads persisted settings");
        });
        test("right button 1, pause ignores input and clears held Ctrl",[&]{
            Fixture f(temporary,"input");Engine e(f);e.open(f);e.start();e.action("param:2:1");e.frame();const auto word=e.word();
            e.pointer(1);check(e.field("overlay")=="menu","right button 1 opens story menu");e.pointer(1);check(e.field("overlay").empty(),"right button 1 closes menu");
            e.key(0x11);ok(engine_pause(e.handle),e.handle,"pause held Ctrl");const auto frozen=e.frame();
            e.key(0x0d);e.key(0x11);e.pointer(1);e.tick(1000);const auto paused=e.frame();
            check(e.field("paused")=="true"&&e.word()==word&&e.field("overlay").empty(),"paused keyboard/pointer ignored");check(paused.desc.frame_serial==frozen.desc.frame_serial&&paused.pixels==frozen.pixels,"paused tick freezes immutable frame");
            ok(engine_resume(e.handle),e.handle,"resume");for(unsigned i=0;i<8;++i)e.tick(100);
            check(e.word()==word&&e.wait()==dialogue_wait,"pause reset Ctrl skip and discarded queued advance");
            e.advance();check(e.word()!=word,"normal input works after resume");
        });
        test("Unicode startup filename",[&]{
            Fixture f(temporary,"unicode");Script unicode;unicode.color(40,170,90);unicode.draw();unicode.print(9,0);unicode.end();
            const auto entry=std::string(u8"場面");binary(f.root/"SpT"/fs::u8path(entry+".SpT"),unicode.encode());
            Engine e(f);e.open(f,entry.c_str());e.until(dialogue_wait);color(e.frame(),40,170,90);
        });
        test("script OPTIONOFF blocks right-click and host menu shortcuts",[&]{
            Fixture f(temporary,"option-off");Script s;s.number(0x3333005aU,{1});s.print(1,0);s.end();binary(f.root/"SpT/SyS.SpT",s.encode());
            Engine e(f);e.open(f);e.action("start");e.until(dialogue_wait);e.pointer(1);check(e.field("overlay").empty(),"OPTIONOFF blocks right-click menu");
            for(const std::string action:{"menu","save","load","settings","backlog","quicksave","quickload"}){e.action(action);check(e.field("overlay").empty(),"OPTIONOFF blocks "+action);}
            check(!fs::exists(f.slot(0)),"OPTIONOFF prevents quicksave file creation");
        });
        test("paused reopen starts an active fresh session",[&]{
            Fixture f(temporary,"paused-reopen");Engine e(f);e.open(f);e.start();
            ok(engine_pause(e.handle),e.handle,"pause before reopen");e.open(f);
            check(e.field("paused")=="false","open clears previous session pause");e.start();e.advance();
        });
        test("missing and invalid story movies resume the suspended script",[&]{
            for(unsigned mode=0;mode<3;++mode){
                Fixture f(temporary,"story-movie-"+std::to_string(mode));
                Script s;s.user(0,{1});s.color(19,73,141);s.draw();s.print(17,0);s.end();binary(f.root/"SpT/SyS.SpT",s.encode());
                text(f.root/"SpT/command.xtx","printmovie,0\n");
                text(f.root/"init/game.xtx","frameTime 20\nprintmovieIsDefault 1\n");
                if(mode){text(f.root/"SpT/movielist.xtx","intro,Intro\n");fs::create_directories(f.root/"movie");}
                if(mode==2)text(f.root/"movie/intro.wmv","invalid movie bytes");
                Engine e(f);e.option("systemnnn.audio","0");e.open(f);e.action("start");e.until(dialogue_wait);
                check(e.field("overlay").empty(),"movie failure resumes story rather than title");color(e.frame(),19,73,141);
            }
        });
        test("return to title cancels active story movie",[&]{
            Fixture f(temporary,"movie-title");Script s;s.user(0,{1});s.print(1,0);s.end();binary(f.root/"SpT/SyS.SpT",s.encode());
            text(f.root/"SpT/command.xtx","printmovie,0\n");text(f.root/"SpT/movielist.xtx","intro,Intro\n");
            text(f.root/"init/game.xtx","frameTime 20\nprintmovieIsDefault 1\n");
            std::string y4m="YUV4MPEG2 W2 H2 F1:1 Ip A1:1 C420jpeg\nFRAME\n";y4m.append(4,char(80));y4m.append(2,char(128));text(f.root/"movie/intro.wmv",y4m);
            Engine e(f);e.option("systemnnn.audio","0");e.open(f);e.action("start");e.tick();
            const auto movie=e.frame();check(movie.pixels[0]>=70&&movie.pixels[0]<=80&&movie.pixels[0]==movie.pixels[1]&&movie.pixels[1]==movie.pixels[2],"story movie began decoding neutral Y80 frame");e.action("title");
            check(e.field("overlay")=="title"&&e.frame().pixels!=movie.pixels,"title action immediately replaces active movie frame");
        });
        test("startup movie failures continue to a usable title",[&]{
            for(unsigned mode=0;mode<2;++mode){
                Fixture f(temporary,"startup-missing-"+std::to_string(mode));
                text(f.root/"init/nothing.xtx","nextMode printMovie\n");
                text(f.root/"init/printMovie.xtx","movieFileName absent.wmv\nnextMode title\n");
                if(mode)text(f.root/"movie/absent.wmv","invalid movie bytes");
                Engine e(f);e.option("systemnnn.audio","0");e.open(f);
                for(unsigned i=0;i<8;++i)e.tick(100);
                check(e.field("overlay")=="title","startup failure reaches title");e.start();
            }
        });
        test("startup filename movie actually plays then reaches title",[&]{
            Fixture f(temporary,"startup-filename");
            text(f.root/"init/nothing.xtx","nextMode printMovie\n");
            text(f.root/"init/printMovie.xtx","movieFileName intro.wmv\nnextMode title\nnoSkipFlag 1\n");
            std::string y4m="YUV4MPEG2 W2 H2 F1:1 Ip A1:1 C420jpeg\nFRAME\n";y4m.append(4,char(80));y4m.append(2,char(128));text(f.root/"movie/intro.wmv",y4m);
            Engine e(f);e.option("systemnnn.audio","0");e.open(f);const auto first=e.frame();
            check(first.desc.width==800&&first.desc.height==600,"startup movie keeps native game canvas dimensions");
            check(first.pixels[0]>=70&&first.pixels[0]<=80&&first.pixels[0]==first.pixels[1]&&first.pixels[1]==first.pixels[2],"configured filename supplies actual decoded neutral Y80 movie");
            for(unsigned i=0;i<20;++i)e.tick(100);
            check(e.frame().pixels!=first.pixels&&e.field("overlay")=="title","movie end restores title canvas");e.start();
        });
        test("native name input validates fields and rejects responses from prior visits",[&]{
            Fixture f(temporary,"native-name");Script s;s.user(0);s.color(21,91,37);s.draw();s.print(1,0);s.end();binary(f.root/"SpT/SyS.SpT",s.encode());
            text(f.root/"SpT/command.xtx","NAMEINPUT,0\n");
            text(f.root/"init/game.xtx","frameTime 20\ncodeByte 1\nNameInputIsDefault 1\nseiInitData Old\nmeiInitData Given\n");
            text(f.root/"init/nameInput.xtx","seiMax 3\nmeiMax 5\nnullNameOk 0\n");
            Engine e(f);e.option("systemnnn.audio","0");e.open(f);e.action("start");e.until(9);e.tick();
            const auto first=Engine::form_id(e.form());
            check(e.answer(first,"","")!=ENGINE_RESULT_OK,"blank names fail declared nonempty policy");check(e.wait()==9,"invalid name leaves modal suspended");
            e.tick();const auto after_blank=Engine::form_id(e.form());
            check(after_blank!=first,"retry has fresh response identity");
            check(e.answer(after_blank,"LongerThanLimit","Given")!=ENGINE_RESULT_OK,"encoded name byte limit enforced");
            e.tick();const auto retry=Engine::form_id(e.form());check(retry!=after_blank,"encoding failure reissues a usable form");
            e.action("title");e.action("start");e.until(9);e.tick();const auto current=Engine::form_id(e.form());
            check(current!=retry,"new story name request has fresh identity");
            check(e.answer(retry)!=ENGINE_RESULT_OK,"old story response cannot complete the new name request");
            check(e.wait()==9,"stale response retains current modal");
            ok(e.answer(current),e.handle,"valid name completion");e.until(dialogue_wait);color(e.frame(),21,91,37);
            e.action("title");e.action("start");e.until(9);e.tick();const auto reopen_old=Engine::form_id(e.form());
            e.open(f);e.action("start");e.until(9);e.tick();const auto reopened=Engine::form_id(e.form());
            check(e.answer(reopen_old)!=ENGINE_RESULT_OK,"response from before open cannot complete reopened name modal");
            ok(e.answer(reopened),e.handle,"name completion after reopen");e.until(dialogue_wait);
        });
        test("chart checkpoints share writable root across new story load and reopen",[&]{
            Fixture f(temporary,"chart-storage");binary(f.root/"sys/ta_chart_button1_1.dwq",puzzle_art());Script s;s.command_adjust.push_back(s.add({5,0x66660003U,0,0,0}));s.print(1,0);s.end();binary(f.root/"SpT/SyS.SpT",s.encode());
            text(f.root/"init/game.xtx","frameTime 20\ncodeByte 1\nSelectChartIsDefault 1\nautoExtDataMode1 selectchart\n");text(f.root/"SpT/command.xtx","selectchart,0\n");
            text(f.root/"init/selectchart.xtx","chartListNumber 1\nbasicChartNumber 1\nchartBlockSize 1000\nslotSizeX 1\nslotSizeY 1\nslotVarName now\nworkVarName prior\n");text(f.root/"chart/chart1.xtx","1800 @1 1 100 100 Fixture\n");
            const std::string names="now\nprior\n";Bytes variables(names.begin(),names.end());for(auto& byte:variables)byte^=0xffU;binary(f.root/"SpT/var.fxf",variables);
            Engine e(f);e.option("systemnnn.audio","0");e.open(f);e.action("start");e.until(9);
            const auto checkpoint=f.writable/"systemnnn/chart1/slot1.dat";check(fs::is_regular_file(checkpoint),"new story writes native chart checkpoint to shared private root");const auto initial=bytes(checkpoint);
            check(!fs::exists(f.writable/"systemnnn/chart/chart1/slot1.dat"),"new story does not create a separate chart directory");
            e.option("systemnnn.save_slot","2");e.action("title");e.option("systemnnn.load_slot","2");check(e.wait()==9&&bytes(checkpoint)==initial,"saved chart modal restores using the same checkpoint root");
            e.open(f);e.action("start");e.until(9);const auto reopened=bytes(checkpoint);check(reopened.size()==initial.size()&&le(reopened,0)==le(initial,0),"reopened new story preserves checkpoint format and location");
        });
        test("progressive dialogue reveal preserves speaker ruby and APPEND acknowledgement",[&]{
            Fixture f(temporary,"progressive-text");Script s;
            const std::string first="A deliberately long opening sentence that reveals gradually.\r\nA separate body row.",tail="ABCD continues with a second row.";
            const auto first_length=static_cast<unsigned>(std::count_if(first.begin(),first.end(),[](char c){return c!='\r'&&c!='\n';}));
            s.messages={"Alice\r\n"+first,"AB#[2phonetic]CD continues with a second row.","Final independent dialogue."};
            s.color(44,88,132);s.draw();s.print(1,0);s.add({6,command,0x22220003U,1,2,0});s.print(3,2);s.end();binary(f.root/"SpT/SyS.SpT",s.encode());
            text(f.root/"init/game.xtx","frameTime 20\ncodeByte 1\n");
            text(f.root/"init/printmessage.xtx","nameFlag 1\nautoNameWindowFlag 1\nappendSkipName 1\nfontSize 20\nprintX 24\nprintY 430\nnextX 10\nnextY 28\nnameX 24\nnameY 400\ncustomMessageSpeed 1\nmessageSpeed1 20\nmessageSpeed2 20\nmessageSpeed3 20\nmessageSpeed4 20\nmessageSpeed5 20\n");
            text(f.root/"SpT/namecol.xtx","Alice 255 255 255\n");
            Engine e(f);e.option("systemnnn.audio","0");e.open(f);e.action("start");e.until(dialogue_wait);
            const auto count=[&](const char* key){return static_cast<unsigned>(std::stoul(e.field(key)));};
            check(count("text_length")==first_length,"speaker and separators do not spend reveal glyphs");
            const auto word=e.word(),visible=count("visible_text");check(visible<first_length&&e.field("text_complete")=="false","first presented dialogue is partial");
            const auto partial=e.frame();e.tick(100);check(e.word()==word&&count("visible_text")==visible+2,"native 20 CPS reveals two glyphs per 100ms");
            const auto more=e.frame();check(more.pixels!=partial.pixels,"partial reveal changes rendered glyphs");
            e.pointer(0,400,500);e.tick();check(e.word()==word&&e.wait()==dialogue_wait&&e.field("text_complete")=="true","first pointer click reveals whole line without advancing");
            const auto complete=e.frame();check(complete.pixels!=more.pixels&&count("visible_text")==first_length,"completed glyphs are rendered before continuation");
            e.pointer(0,400,500);e.tick();e.until(dialogue_wait);check(e.word()!=word,"next click advances after completed frame acknowledgement");
            const auto appended=e.word();check(count("text_length")==first_length+tail.size(),"APPEND timing excludes ruby annotation bytes; "+e.debug());
            check(count("visible_text")>=first_length&&count("visible_text")<first_length+tail.size(),"APPEND preserves old body while revealing only the suffix");
            const auto append_visible=count("visible_text");e.tick(100);check(count("visible_text")==append_visible+2&&e.word()==appended,"ruby base glyphs use native reveal timing");
            e.pointer(0,400,500);e.tick();check(e.word()==appended&&e.field("text_complete")=="true","first APPEND click completes suffix only");e.frame();
            e.pointer(0,400,500);e.tick();e.until(dialogue_wait);check(e.word()!=appended,"completed APPEND advances on following click");
        });
        test("progressive dialogue Auto settings and script AUTOMESSAGE use native wait",[&]{
            for(unsigned scripted=0;scripted<2;++scripted){
                Fixture f(temporary,"progressive-auto-"+std::to_string(scripted));Script s;s.messages={"ABCDEFGHIJ","A second sentence stays pending."};
                if(scripted)s.number(0x33330057U,{1});s.print(1,0);if(scripted)s.number(0x33330057U,{UINT32_MAX});s.print(2,1);s.end();binary(f.root/"SpT/SyS.SpT",s.encode());
                text(f.root/"init/game.xtx","frameTime 20\ncodeByte 1\n");
                text(f.root/"init/printmessage.xtx","nameFlag 0\ncustomMessageSpeed 1\nmessageSpeed1 20\nmessageSpeed2 20\nmessageSpeed3 20\nmessageSpeed4 20\nmessageSpeed5 20\nnoVoiceLastWait 100\nautoMessageLastWait 100\nautoMessageWaitVoiceFlag 0\n");
                Engine e(f);e.option("systemnnn.audio","0");e.open(f);e.action("start");e.until(dialogue_wait);const auto word=e.word();
                if(!scripted){e.action("param:6:1");check(e.field("auto_mode")=="true","system parameter enables provider Auto state");}
                for(unsigned n=0;e.field("text_complete")!="true"&&n<10;++n){e.tick(50);check(e.word()==word,"Auto cannot skip a partially revealed line");}
                check(e.field("text_complete")=="true"&&e.word()==word,"last-glyph frame retains the dialogue");e.frame();
                e.tick(99);check(e.word()==word,"native Auto wait retains all but final millisecond");e.tick(1);
                for(unsigned n=0;e.word()==word&&n<3;++n)e.tick(20);
                check(e.word()!=word&&e.wait()==dialogue_wait,"Auto advances after native completed-text wait");
                if(!scripted){e.action("auto");check(e.field("auto_mode")=="false","Auto action turns off the native system parameter");const auto second=e.word();e.tick(5000);e.tick(5000);check(e.word()==second,"Auto action turns off the setting previously enabled through system parameter");
                    e.option("systemnnn.auto","1");check(e.field("auto_mode")=="true","Auto option shares native parameter with settings and action");e.tick(100);e.tick(20);check(e.word()!=second||e.field("overlay")=="title","Auto option re-enables native parameter for continuation");}
                else {const auto second=e.word();e.tick(5000);e.tick(5000);check(e.word()==second,"script AUTOMESSAGE off leaves manual line pending");}
            }
        });
        test("script term modal Return resumes its script caller",[&]{
            Fixture f(temporary,"script-term");Script s;s.user(0);s.color(33,92,144);s.draw();s.print(8,0);s.end();binary(f.root/"SpT/SyS.SpT",s.encode());
            text(f.root/"SpT/command.xtx","printterm,0\n");text(f.root/"init/game.xtx","frameTime 20\ncodeByte 1\nPrintTermIsDefault 1\n");
            text(f.root/"init/printTerm.xtx","termTypeNumber 1\ntermPerPage 1\n");text(f.root/"SpT/termList.xtx","Fixture,1,0,fixture\n");text(f.root/"nya/term/fixture.xtx","Independent term description\n");
            Engine e(f);e.option("systemnnn.audio","0");e.open(f);e.action("start");e.until(9);e.action("modal:action:0:0");
            check(e.field("overlay").empty(),"script-origin term Return does not route to title");e.until(dialogue_wait);color(e.frame(),33,92,144);
            e.action("title");e.action("start");e.until(9);e.key(0x1b);e.tick();e.until(dialogue_wait);check(e.field("overlay").empty(),"Escape and modal Return share script continuation");
        });
        test("minigame title and omake input lifecycle and Change solve through ABI",[&]{
            Fixture f(temporary,"minigame-abi");binary(f.root/"sys/puzzle.dwq",puzzle_art());
            text(f.root/"init/title.xtx","enterFadeType 0\nminiGameFlag 1\n");text(f.root/"init/omake.xtx","miniGameFlag 1\n");
            text(f.root/"init/minigame.xtx","addMiniGame 2\nminiGame1 2\nminiGame2 2\nminiGameCheckMode1 title\nminiGameCheckMode2 omake\nminiGameCheckX1 700\nminiGameCheckY1 100\nminiGameCheckSizeX1 80\nminiGameCheckSizeY1 40\nminiGameCheckX2 700\nminiGameCheckY2 100\nminiGameCheckSizeX2 80\nminiGameCheckSizeY2 40\nnoCGFileName puzzle\nexitPrintX 760\nexitPrintY 570\nexitSizeX 40\nexitSizeY 30\nsetCGNumber1 1\nsetCGPlayer1_1 1\nsetCGParam1_1 1\n");
            Engine e(f);e.option("systemnnn.audio","0");e.open(f);e.pointer(0,720,120);e.tick();
            check(e.field("minigame_active")=="true"&&e.field("overlay")=="title","configured title area opens minigame");
            const auto board=e.frame();std::vector<unsigned> values(16);std::vector<bool> seen(16,false);
            for(unsigned i=0;i<16;++i){const auto p=(static_cast<std::size_t>(i/4*150+12)*800+i%4*200+12)*4;const unsigned red=board.pixels[p];check(red>=20&&(red-20)%12==0,"rendered tile identifies authored source art");values[i]=(red-20)/12;check(values[i]<16&&!seen[values[i]],"board is a permutation of authored tiles");seen[values[i]]=true;}
            e.point(ENGINE_INPUT_EVENT_POINTER_DOWN,100,75);e.point(ENGINE_INPUT_EVENT_POINTER_UP,100,75,ENGINE_INPUT_MODIFIER_POINTER_CANCEL);e.tick();check(e.frame().pixels==board.pixels,"cancelled touch does not pick up a tile");
            ok(engine_pause(e.handle),e.handle,"pause minigame");e.click(100,75);check(e.frame().pixels==board.pixels,"paused minigame ignores board input");ok(engine_resume(e.handle),e.handle,"resume minigame");
            // Sort the visible permutation using only public pointer events. Moving
            // the cursor outside the viewport keeps the held tile clear of samples.
            const auto choose=[&](unsigned i){e.point(ENGINE_INPUT_EVENT_POINTER_DOWN,i%4*200+100,i/4*150+75);e.point(ENGINE_INPUT_EVENT_POINTER_UP,i%4*200+100,i/4*150+75);e.point(ENGINE_INPUT_EVENT_POINTER_MOVE,-1000,-1000);e.tick();};
            for(unsigned i=0;i<16;++i){if(values[i]==i)continue;const auto pos=std::find(values.begin(),values.end(),i)-values.begin();check(pos<16,"target tile found");choose(i);choose(static_cast<unsigned>(pos));choose(i);std::swap(values[i],values[pos]);}
            e.tick();check((persisted_block_word(f,7,8)&1U)!=0,"solving via ABI commits configured CG reward to PC global save");
            e.key(0x1b);e.tick();check(e.field("minigame_active")=="false"&&e.field("overlay")=="title","Escape returns to title caller");
            e.action("extras");e.pointer(0,720,120);e.tick();check(e.field("minigame_active")=="true"&&e.field("overlay")=="omake","configured omake area opens its own minigame");
            e.click(780,585);check(e.field("minigame_active")=="false"&&e.field("overlay")=="omake","exit hit returns to omake caller");
            e.action("settings");e.action("back");check(e.field("overlay")=="omake","closing settings opened from Omake preserves the Omake caller");
            e.action("minigame:1");e.key(0x1b);e.tick();check(e.field("overlay")=="omake"&&e.field("minigame_active")=="false","omake Escape preserves caller");
            e.action("minigame:1");e.open(f);check(e.field("minigame_active")=="false"&&e.field("overlay")=="title","reopen discards active board");
            e.start();check(set(e,"systemnnn.action","minigame:0")!=ENGINE_RESULT_OK,"story cannot invoke title-only minigame");
        });
        test("invalid open recovery",[&]{
            Fixture f(temporary,"recovery");Engine e(f);e.option("runtime","systemnnn");e.open(f);
            const auto invalid=(temporary/"invalid").u8string();fs::create_directories(fs::u8path(invalid));
            check(engine_open_game(e.handle,invalid.c_str(),nullptr)!=ENGINE_RESULT_OK,"invalid root open rejected");
            e.open(f);check(e.field("overlay")=="title","valid open recovers after invalid root");e.start();color(e.frame(),180,30,60);
        });
        test("repeat create/open/destroy with enabled null-driver audio",[&]{
            Fixture f(temporary,"audio");
            for(unsigned i=0;i<3;++i){Engine e(f);e.option("systemnnn.audio","1");e.open(f);check(e.field("audio_error").empty(),"OpenAL null driver started");e.start();e.tick();ok(engine_pause(e.handle),e.handle,"audio pause");ok(engine_resume(e.handle),e.handle,"audio resume");e.open(f);check(e.field("overlay")=="title","audio reopen reaches title");e.destroy();}
        });
        if(failures){std::cerr<<failures<<" provider fixture(s) failed; retained at "<<temporary<<'\n';return 1;}
        if(std::getenv("SYSTEMNNN_KEEP_FIXTURES"))std::cout<<"Fixtures retained at "<<temporary<<'\n';
        else fs::remove_all(temporary);
        return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<"\nFixtures retained at "<<temporary<<'\n';return 1;}
}
