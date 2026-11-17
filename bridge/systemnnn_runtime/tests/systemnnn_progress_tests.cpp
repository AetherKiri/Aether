// Standalone: compile this translation unit, which includes the implementation,
// against the same emberfall-scene and core libraries as the native provider.
#include "../src/systemnnn_progress.cpp"
#include <iostream>
#include <sstream>

namespace aether::systemnnn {
namespace {
void require(bool ok,const std::string& message){if(!ok)throw std::runtime_error(message);}
void clean(const Warnings& warnings){for(const auto& w:warnings)if(w.find("SYSTEMFLAG2")==std::string::npos)throw std::runtime_error(w);}
struct Temp {
    fs::path path;
    Temp(){path=fs::temp_directory_path()/("aether-progress-tests-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));fs::create_directories(path);}
    ~Temp(){std::error_code ignored;fs::remove_all(path,ignored);}
};
std::unique_ptr<GameSession> session(const fs::path& root){directory(root/"spt");emberfall::scene::SessionOptions o;o.width=16;o.height=16;o.audio.enabled=false;o.analyze_executable=false;return GameSession::create_ui_preview(root,o);}
void text_file(const fs::path& path,const std::string& s){directory(path.parent_path());std::ofstream out(path,std::ios::binary);out<<s;require(bool(out),"fixture write");}
void export_java_fixtures(const fs::path& path){
    directory(path);State s;s.read={1,0x12340002};s.variables[999]=-123;s.results[1029]=100;s.text.surname="Last";s.text.given_name="First";s.text.system_replacements[3]="replacement";s.optional.terms[7]=3;s.optional.voice_words[15625]=1;s.optional.voice_role_words[7]=0x80000000U;s.chart=chart_bytes(nnn::chart::Progress{Bytes(4,1),Bytes(3,2)});
    const auto base=encode_base(s);atomic_write(path/"emberfall.read",base);Bytes ext;be(ext,0x4e4e4533);ext.push_back(1);extension_record(ext,sha256(base),s);atomic_write(path/"emberfall.read.ext",ext);atomic_write(path/"emberfall.gallery",encode_gallery({0x10010003,0x30000001,0x50020003}));
    for(int version=1;version<=3;++version)atomic_write(path/(std::string("sysfile")+(version==1?"":std::to_string(version))+".sav"),create_archive(version).bytes);
}
void hash_test(){const auto h=sha256(Bytes{'a','b','c'});constexpr nnn::Byte expected[]={0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad};require(std::equal(h.begin(),h.end(),std::begin(expected)),"SHA-256 standard vector");}
void codec_test(){
    State s;s.read={1,0x1fff0001};s.variables[999]=-123;s.results[1024]=42;s.text.surname="raw";s.text.system_replacements[99]=std::string(32,'x');s.optional.terms[3]=3;s.optional.voice_words[16383]=0x80000000U;s.optional.voice_role_words[7]=0x80000000U;s.legacy={{0xc0,0x80},{'a'}};
    s.chart=chart_bytes(nnn::chart::Progress{Bytes(4,1),Bytes(3,2)});
    const auto base=encode_base(s);auto d=decode_base(base);require(d.read==s.read&&d.variables==s.variables&&d.results==s.results&&d.legacy==s.legacy,"NNR4 exact field roundtrip");
    Bytes ext;be(ext,0x4e4e4533);ext.push_back(1);extension_record(ext,sha256(base),s);require(decode_extension(ext,sha256(base),d),"NNE3 pairing");require(d.text==s.text&&d.optional==s.optional&&d.chart==s.chart,"NNE3 full roundtrip");
    auto other=sha256(Bytes{4});State unmatched;require(!decode_extension(ext,other,unmatched),"mismatched generation ignored");
    auto bad=base;bad.pop_back();bool caught=false;try{decode_base(bad);}catch(...){caught=true;}require(caught,"truncated NNR4 rejected");
    auto gallery=std::vector<Word>{0x10010003,0x20010002,0x30000001,0x40000000,0x50020003};require(decode_gallery(encode_gallery(gallery))==gallery,"NNG1 roundtrip");
    auto corrupt=encode_gallery({0x30000100});caught=false;try{decode_gallery(corrupt);}catch(...){caught=true;}require(caught,"invalid gallery key rejected");
}
void version_test(int version){
    Temp t;const auto root=t.path/"game",writable=t.path/"private";directory(root);text_file(root/"init"/"game.xtx","resultFlag 1\nexpModeButtonIsMessageCursor 1\n");
    auto game=session(root);const auto filename=std::string("sysfile")+(version==1?"":std::to_string(version))+".sav";const ProgressOptions options{filename};
    auto a=create_archive(version);const auto count=le(a.bytes,32);require(count==static_cast<unsigned>(version==1?10:version==2?14:16),"PC block count");
    // Preserve fields that this adapter neither understands nor owns, including SCENEFLAG.
    a.bytes[a.at(1)+2000]=0xab;a.bytes[a.at(8)+50]=0xcd;a.bytes[a.at(6)+block_size(3,version)-1]=0xef;atomic_write(root/"sav"/filename,a.bytes);const auto original=a.bytes;
    auto& runtime=*game->runtime();runtime.mark_read(0x00010007);runtime.mark_read(0x12340009);runtime.unlock_gallery(nnn::GalleryKind::Cg,1,3);runtime.unlock_gallery(nnn::GalleryKind::Choice,10,4);runtime.unlock_gallery(nnn::GalleryKind::Movie,0,0);
    runtime.set_system_variable(5,-1234);runtime.set_system_variable(999,2345);runtime.set_achievement(5,100);runtime.set_result_if_clear(4,2);runtime.set_system_name("Last","First");runtime.set_system_replacement(3,"replacement");runtime.set_term_unlocked(7);runtime.set_voice_played(500000);runtime.mark_voice_role_heard(255);
    runtime.set_system_parameter(100,57);runtime.set_system_parameter(500,-15);runtime.set_system_parameter(300,3);runtime.set_message_window(4);runtime.set_system_voice_selection(7);auto off=runtime.voice_off();off[31]=0xdeadbeef;runtime.set_voice_off(off);
    clean(save_progress(*game,root,writable,options));require(*read_file(root/"sav"/filename)==original,"original import remains untouched");
    const auto saved=*read_file(writable/"systemnnn"/filename);Archive pc(saved,version);require(pc.bytes[pc.at(1)+2000]==0xab&&pc.bytes[pc.at(8)+50]==0xcd&&pc.bytes[pc.at(6)+block_size(3,version)-1]==0xef,"unknown bytes preserved");
    require(pc.word(6,13)==static_cast<Word>(-1234)&&pc.word(1,44)==57,"PC variable/settings words");require(pc.bit(5,131072+7),"PC read stride");require(pc.bit(11,1),"movie is one based");
    const auto previous_base=*read_file(writable/"systemnnn"/"emberfall.read");const auto previous=snapshot(runtime);runtime.set_system_variable(6,99);runtime.set_system_replacement(3,"next");clean(save_progress(*game,root,writable,options));
    const auto extension=*read_file(writable/"systemnnn"/"emberfall.read.ext");State prior=decode_base(previous_base);require(decode_extension(extension,sha256(previous_base),prior)&&prior.text==previous.text,"previous generation survives interrupted base commit");
    auto restarted=session(root);clean(load_progress(*restarted,root,writable,options));auto& loaded=*restarted->runtime();require(loaded.is_read(0x00010007)&&loaded.is_read(0x12340009),"read flags survive restart");require(loaded.system_variable(5)==-1234&&loaded.system_variable(999)==2345&&loaded.system_variable(6)==99,"all system variables survive");require(loaded.runtime_text().surname=="Last"&&loaded.system_replacement(3)=="next","global text survives");require(loaded.term_unlocked(7)&&loaded.voice_played(500000)&&loaded.voice_role_heard(255),"optional progress survives");require(loaded.script_progress()[1029]==100&&loaded.result_value(4)==2,"results and achievements survive");require(loaded.snapshot_parameters().get(100)==57&&loaded.snapshot_parameters().get(500)==-15,"raw parameters survive");require(loaded.snapshot_gallery().size()==3,"all galleries including unsupported classic choices survive");require(loaded.voice_off()[31]==0xdeadbeef&&loaded.message_window()==4,"dedicated audio owners survive");if(version==3)require(loaded.system_voice_selection()==7,"system voice theme survives");
    const Bytes broken{1,2,3};atomic_write(writable/"systemnnn"/filename,broken);const auto warning=save_progress(*game,root,writable,options);require(!warning.empty()&&*read_file(writable/"systemnnn"/filename)==broken,"damaged PC progress remains unchanged");
    atomic_write(writable/"systemnnn"/"emberfall.read",broken);const auto warning2=save_progress(*game,root,writable,options);require(!warning2.empty()&&*read_file(writable/"systemnnn"/"emberfall.read")==broken,"damaged sidecar remains unchanged");
}
void chart_test(bool legacy){
    Temp t;const auto root=t.path/"game",writable=t.path/"private";directory(root);
    text_file(root/"init"/"game.xtx",legacy?"extSaveDataNumber 1\nextSaveDataSize1 11280\n":"SelectChartIsDefault 1\n");
    text_file(root/"init"/(legacy?"chart.xtx":"selectChart.xtx"),"chartListNumber 1\nbasicChartNumber 1\nchartBlockSize 1000\nslotSizeX 1\nslotSizeY 1\n");
    text_file(root/"chart"/"chart1.xtx",legacy?"1800 @1001 1 100 100 First\n":"1800 @1 1 100 100 First\n");
    if(legacy){text_file(root/"spt"/"command.xtx","chartmap,d\n");text_file(root/"spt"/"function.xtx","genzaichi,d\n");}
    auto game=session(root);game->set_chart_storage(writable/"systemnnn");
    require(game->legacy_chart()==legacy,"chart variant recognized");
    const nnn::chart::Graph graph(root,800,600,{},legacy?nnn::chart::Variant::LegacyChart:nnn::chart::Variant::SelectChart);
    auto progress=graph.global_defaults();progress.seen[1]=3;progress.traversed[2]=5;require(game->restore_chart_progress(progress),"native chart restore");
    const ProgressOptions options{"sysfile3.sav"};clean(save_progress(*game,root,writable,options));
    const auto dir=legacy?writable/"systemnnn"/"mushiex":writable/"systemnnn";
    require(read_file(dir/"mita.dat")->size()==(legacy?10004U:1000U)&&(*read_file(dir/"tsuka.dat"))[2]==5,"exact PC chart files");
    auto restarted=session(root);restarted->set_chart_storage(writable/"systemnnn");clean(load_progress(*restarted,root,writable,options));
    const auto restored=restarted->runtime()->chart_progress();require(restored&&restored->seen==progress.seen&&restored->traversed==progress.traversed,"chart restart roundtrip");
    atomic_write(dir/"mita.dat",Bytes{9});const auto warnings=save_progress(*game,root,writable,options);require(!warnings.empty()&&*read_file(dir/"mita.dat")==Bytes{9},"damaged chart preserved");
}
void failure_test(){
    Temp t;const auto root=t.path/"game",writable=t.path/"private";directory(root);auto game=session(root);const ProgressOptions options{"sysfile3.sav"};
    clean(save_progress(*game,root,writable,options));const auto dir=writable/"systemnnn";
    const auto base=*read_file(dir/"emberfall.read");const auto ext=*read_file(dir/"emberfall.read.ext");
    atomic_write(dir/"emberfall.read.ext",Bytes{1});game->runtime()->set_system_variable(5,77);
    require(!save_progress(*game,root,writable,options).empty()&&*read_file(dir/"emberfall.read")==base&&*read_file(dir/"emberfall.read.ext")==Bytes{1},"damaged extension prevents base replacement");
    atomic_write(dir/"emberfall.read.ext",ext);atomic_write(dir/"emberfall.gallery",Bytes{2});
    require(!save_progress(*game,root,writable,options).empty()&&*read_file(dir/"emberfall.gallery")==Bytes{2},"damaged gallery preserved");
    directory(dir/"result.sav");text_file(root/"init"/"game.xtx","resultFlag 1\n");require(!save_progress(*game,root,writable,options).empty()&&fs::is_directory(dir/"result.sav"),"directory save target preserved");
    const auto invalid_name=save_progress(*game,root,writable,ProgressOptions{"../sysfile3.sav"});require(!invalid_name.empty(),"filename traversal rejected");
#ifndef _WIN32
    const auto outside=t.path/"untouched";atomic_write(outside,Bytes{6});fs::create_symlink(outside,dir/"tsysfile3.sav");
    require(!save_progress(*game,root,writable,ProgressOptions{"tsysfile3.sav"}).empty()&&*read_file(outside)==Bytes{6},"symlink target not overwritten");
#endif
}
void empty_directory_test(){Temp t;const auto root=t.path/"game";directory(root);auto game=session(root);clean(save_progress(*game,root,{},ProgressOptions{"tsysfile3.sav"}));require(fs::exists(root/"sav"/"tsysfile3.sav"),"empty writable uses root/sav");const auto first=*read_file(root/"sav"/"tsysfile3.sav");clean(save_progress(*game,root,{},ProgressOptions{"tsysfile3.sav"}));require(first==*read_file(root/"sav"/"tsysfile3.sav"),"unchanged save does not stamp or rewrite");}
}
}
int main(int argc,char** argv){try{using namespace aether::systemnnn;if(argc==2){export_java_fixtures(fs::u8path(argv[1]));return 0;}hash_test();codec_test();for(int version=1;version<=3;++version)version_test(version);chart_test(false);chart_test(true);failure_test();empty_directory_test();std::cout<<"SystemNNN progress standalone tests passed\n";return 0;}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
