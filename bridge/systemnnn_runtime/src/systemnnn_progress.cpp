#include "systemnnn_progress.h"
#include "emberfall/game_session.hpp"
#include "nnn/chart_graph.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <ctime>
#include <fstream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <system_error>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#endif

namespace aether::systemnnn {
namespace {
namespace fs=std::filesystem;
using GameSession=emberfall::scene::GameSession;
using Bytes=std::vector<nnn::Byte>;
using Word=nnn::Word;
using Value=nnn::Value;
using Warnings=std::vector<std::string>;
constexpr std::size_t max_file=32U*1024U*1024U,max_pc=147456,max_chart=256U*1024U;
[[noreturn]] void invalid(const std::string& what) { throw std::runtime_error(what+"; original retained"); }
Word le(const Bytes& b,std::size_t p) {
    if(p>b.size() || b.size()-p<4) invalid("Truncated progress word");
    return Word(b[p])|(Word(b[p+1])<<8U)|(Word(b[p+2])<<16U)|(Word(b[p+3])<<24U);
}
Value signed_word(Word w) { return w<=0x7fffffffU?static_cast<Value>(w):-1-static_cast<Value>(~w); }
void put(Bytes& b,std::size_t p,Word w) {
    if(p>b.size() || b.size()-p<4) invalid("Progress word outside block");
    for(unsigned i=0;i<4;++i)b[p+i]=static_cast<nnn::Byte>(w>>(i*8));
}
void be(Bytes& b,Word w,unsigned count=4) {for(unsigned i=count;i>0;--i)b.push_back(static_cast<nnn::Byte>(w>>((i-1)*8)));}
struct Reader {
    const Bytes& b;std::size_t p=0;
    Word get(unsigned n=4) {if(p>b.size() || n>b.size()-p)invalid("Truncated global progress");Word w=0;while(n--)w=(w<<8)|b[p++];return w;}
    Bytes take(std::size_t n) {if(p>b.size() || n>b.size()-p)invalid("Truncated global progress payload");Bytes r(b.begin()+p,b.begin()+p+n);p+=n;return r;}
    void end() {if(p!=b.size())invalid("Unexpected global progress payload");}
};
std::optional<Bytes> read_file(const fs::path& path,std::size_t limit=max_file) {
    const auto status=fs::symlink_status(path);
    if(status.type()==fs::file_type::not_found)return {};
    if(!fs::is_regular_file(status))invalid("Not a regular progress file: "+path.u8string());
    const auto size=fs::file_size(path);
    if(size>limit)invalid("Progress exceeds size limit: "+path.u8string());
    std::ifstream in(path,std::ios::binary);Bytes bytes(static_cast<std::size_t>(size));
    if(!in || (size && !in.read(reinterpret_cast<char*>(bytes.data()),static_cast<std::streamsize>(size))))
        invalid("Cannot read progress: "+path.u8string());
    char extra=0;if(in.get(extra)||in.bad()||!in.eof())invalid("Progress changed while reading: "+path.u8string());
    return bytes;
}
fs::path named(const fs::path& directory,const std::string& name) {
    // Keep the exact case of original PC names, even on a case-sensitive host.
    const auto status=fs::symlink_status(directory);
    if(status.type()==fs::file_type::not_found)return directory/fs::u8path(name);
    if(!fs::is_directory(status))invalid("Invalid progress directory: "+directory.u8string());
    fs::path found;
    for(const auto& entry:fs::directory_iterator(directory))
        if(nnn::game_config::ascii_lower(entry.path().filename().u8string())==nnn::game_config::ascii_lower(name)) {
            if(!found.empty())invalid("Ambiguous progress filename: "+name);
            found=entry.path();
        }
    return found.empty()?directory/fs::u8path(name):found;
}
void directory(const fs::path& path) {
    fs::create_directories(path);
    if(!fs::is_directory(fs::symlink_status(path)))invalid("Invalid progress directory: "+path.u8string());
}
void atomic_write(const fs::path& path,const Bytes& bytes) {
    directory(path.parent_path());
    // Check existing files before replacing; directories and symlinks are never followed.
    const auto status=fs::symlink_status(path);
    if(status.type()!=fs::file_type::not_found && !fs::is_regular_file(status))invalid("Invalid progress target: "+path.u8string());
    static std::atomic<unsigned long long> serial{0};
    fs::path temp;
#ifdef _WIN32
    HANDLE handle=INVALID_HANDLE_VALUE;
    for(unsigned attempt=0;attempt<128 && handle==INVALID_HANDLE_VALUE;++attempt) {
        temp=path.parent_path()/fs::u8path(".systemnnn-"+std::to_string(GetCurrentProcessId())+"-"+std::to_string(++serial)+".tmp");
        handle=CreateFileW(temp.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(handle==INVALID_HANDLE_VALUE && GetLastError()!=ERROR_FILE_EXISTS)throw std::system_error(GetLastError(),std::system_category(),"Create progress staging file");
    }
    if(handle==INVALID_HANDLE_VALUE)throw std::runtime_error("Cannot allocate progress staging file");
    try {
        std::size_t done=0;
        while(done<bytes.size()) {DWORD written=0;const auto count=static_cast<DWORD>(std::min<std::size_t>(bytes.size()-done,1U<<20));
            if(!WriteFile(handle,bytes.data()+done,count,&written,nullptr)||!written)throw std::system_error(GetLastError(),std::system_category(),"Write progress");done+=written;}
        if(!FlushFileBuffers(handle))throw std::system_error(GetLastError(),std::system_category(),"Flush progress");
        if(!CloseHandle(handle)) {handle=INVALID_HANDLE_VALUE;throw std::system_error(GetLastError(),std::system_category(),"Close progress");}handle=INVALID_HANDLE_VALUE;
        if(!MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::system_error(GetLastError(),std::system_category(),"Replace progress");
    } catch(...) {if(handle!=INVALID_HANDLE_VALUE)CloseHandle(handle);DeleteFileW(temp.c_str());throw;}
#else
    int fd=-1;
    for(unsigned attempt=0;attempt<128 && fd<0;++attempt) {
        temp=path.parent_path()/fs::u8path(".systemnnn-"+std::to_string(getpid())+"-"+std::to_string(++serial)+".tmp");
        fd=::open(temp.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
        if(fd<0 && errno!=EEXIST)throw std::system_error(errno,std::generic_category(),"Create progress staging file");
    }
    if(fd<0)throw std::runtime_error("Cannot allocate progress staging file");
    try {
        std::size_t done=0;
        while(done<bytes.size()) {const auto n=::write(fd,bytes.data()+done,bytes.size()-done);if(n<0 && errno==EINTR)continue;
            if(n<=0)throw std::system_error(errno,std::generic_category(),"Write progress");
            done+=static_cast<std::size_t>(n);}
        if(::fsync(fd)!=0)throw std::system_error(errno,std::generic_category(),"Flush progress");
        const auto close_result=::close(fd);fd=-1;if(close_result!=0)throw std::system_error(errno,std::generic_category(),"Close progress");
        if(::rename(temp.c_str(),path.c_str())!=0)throw std::system_error(errno,std::generic_category(),"Replace progress");
        const int dir=::open(path.parent_path().c_str(),O_RDONLY|O_DIRECTORY|O_CLOEXEC);
        if(dir<0)throw std::system_error(errno,std::generic_category(),"Open progress directory for sync");
        const auto synced=::fsync(dir);const auto error=errno;::close(dir);
        if(synced!=0)throw std::system_error(error,std::generic_category(),"Sync progress directory");
    } catch(...) {if(fd>=0)::close(fd);::unlink(temp.c_str());throw;}
#endif
}
template<class Function> void guarded(Warnings& out,const std::string& part,Function&& fn) {
    try {fn();}catch(const std::exception& e){out.push_back(part+": "+e.what());}
}
// SHA-256 commits NNE extension generations to the exact Java NNR4 byte stream.
std::array<nnn::Byte,32> sha256(Bytes input) {
    constexpr Word k[]={0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
    std::array<Word,8> h{{0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}};
    const auto bits=static_cast<std::uint64_t>(input.size())*8;input.push_back(0x80);while(input.size()%64!=56)input.push_back(0);
    be(input,static_cast<Word>(bits>>32));be(input,static_cast<Word>(bits));
    const auto rot=[](Word w,unsigned n){return (w>>n)|(w<<(32-n));};
    for(std::size_t p=0;p<input.size();p+=64) {
        Word w[64]{};for(unsigned i=0;i<16;++i)for(unsigned j=0;j<4;++j)w[i]=(w[i]<<8)|input[p+i*4+j];
        for(unsigned i=16;i<64;++i)w[i]=w[i-16]+(rot(w[i-15],7)^rot(w[i-15],18)^(w[i-15]>>3))+w[i-7]+(rot(w[i-2],17)^rot(w[i-2],19)^(w[i-2]>>10));
        Word a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],z=h[7];
        for(unsigned i=0;i<64;++i) {const auto t=z+(rot(e,6)^rot(e,11)^rot(e,25))+((e&f)^(~e&g))+k[i]+w[i];
            const auto u=(rot(a,2)^rot(a,13)^rot(a,22))+((a&b)^(a&c)^(b&c));z=g;g=f;f=e;e=d+t;d=c;c=b;b=a;a=t+u;}
        h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=z;
    }
    std::array<nnn::Byte,32> result{};for(unsigned i=0;i<8;++i)for(unsigned j=0;j<4;++j)result[i*4+j]=static_cast<nnn::Byte>(h[i]>>(24-j*8));return result;
}

constexpr int codes[]={0,1,5,6,7,8,9,10,11,12,13,14,15,16,17,18};
constexpr std::size_t sizes[]={64,2048,32800,4128,1312,2080,16416,1056,1056,1056,6432,4128,4128,65568,1056,4128};
constexpr const char* labels[]={"FILE INFO","SYSTEM DATA","MES FLAG","SYSTEMVAR","CGFLAG","SCENEFLAG","FILMFLAG","VOICEFLAG","MOVIEFLAG","MUSICFLAG","OKIKAE","ACHIEVEMENT","TERM","CHARAVOICEFLAG","SYSTEMFLAG2","SELECTMESSAGE"};
constexpr std::pair<Word,int> fields[]={{2,35},{4,21},{6,41},{100,44},{101,46},{102,45},{103,47},{104,53},{105,34},{106,483},{107,55},{108,492},{109,-12},
    {200,48},{201,50},{202,49},{203,51},{204,54},{208,493},{209,-13},{210,-10},{211,-16},{212,-11},{213,-15},{214,-9}};
std::size_t block_size(std::size_t i,int version) {return codes[i]==6 && version==1?544:sizes[i];}
struct Archive {
    Bytes bytes;std::array<std::size_t,19> offsets{};int version;
    Archive(Bytes b,int v):bytes(std::move(b)),version(v) {
        offsets.fill(std::numeric_limits<std::size_t>::max());
        if(bytes.size()<64||bytes.size()>max_pc)invalid("Invalid PC global save length");
        const auto count=le(bytes,32);
        if(count<10||count>16||(v==2 && count>14)||(v==3 && count!=16))invalid("Invalid PC global save block count");
        std::size_t offset=0;
        for(std::size_t i=0;i<count;++i) {
            const auto size=block_size(i,v);if(size>bytes.size()-offset||le(bytes,offset)!=size||le(bytes,offset+4)!=static_cast<Word>(codes[i]))invalid("Invalid PC global save block layout");
            const std::string label=std::string(labels[i])+std::string(15-std::strlen(labels[i]),' ');
            if(!std::equal(label.begin(),label.end(),bytes.begin()+offset+16))invalid("Invalid PC global save block label");
            offsets[codes[i]]=offset;offset+=size;
        }
        if(offset!=bytes.size())invalid("Unexpected PC global save trailing bytes");
    }
    bool has(unsigned code)const{return offsets[code]!=std::numeric_limits<std::size_t>::max();}
    std::size_t at(unsigned code)const {if(!has(code))invalid("PC progress block absent");return offsets[code];}
    std::size_t payload(unsigned code)const{return at(code)+32;}
    Word word(unsigned code,std::size_t index)const{return le(bytes,at(code)+index*4);}
    void word(unsigned code,std::size_t index,Word value){put(bytes,at(code)+index*4,value);}
    bool bit(unsigned code,std::size_t index)const{return (bytes[payload(code)+index/8]&(1U<<(index%8)))!=0;}
    void set_bit(unsigned code,std::size_t index){bytes[payload(code)+index/8]|=static_cast<nnn::Byte>(1U<<(index%8));}
    std::string text(std::size_t at,std::size_t limit)const {std::size_t end=at;while(end<at+limit&&bytes[end])++end;return std::string(reinterpret_cast<const char*>(bytes.data()+at),end-at);}
    void text(std::size_t at,std::size_t size,std::size_t limit,const std::string& value) {
        if(text(at,limit)==value)return;
        std::fill(bytes.begin()+at,bytes.begin()+at+size,0);std::copy_n(value.begin(),std::min(limit,value.size()),bytes.begin()+at);
    }
    void stamp() {
        const auto now=std::chrono::system_clock::now();const auto time=std::chrono::system_clock::to_time_t(now);std::tm tm{};
#ifdef _WIN32
        localtime_s(&tm,&time);
#else
        localtime_r(&time,&tm);
#endif
        const Word date[]={static_cast<Word>(tm.tm_year+1900),static_cast<Word>(tm.tm_mon+1),static_cast<Word>(tm.tm_mday),static_cast<Word>(tm.tm_wday),
            static_cast<Word>(tm.tm_hour),static_cast<Word>(tm.tm_min),static_cast<Word>(tm.tm_sec),static_cast<Word>(std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count()%1000)};
        for(unsigned i=0;i<8;++i)word(1,8+i,date[i]);
        word(1,23,word(1,23)+1);
    }
};
Archive create_archive(int version) {
    const std::size_t count=version==1?10:version==2?14:16;std::size_t total=0;for(std::size_t i=0;i<count;++i)total+=block_size(i,version);
    Bytes b(total);std::size_t p=0;for(std::size_t i=0;i<count;++i) {put(b,p,static_cast<Word>(block_size(i,version)));put(b,p+4,codes[i]);
        const std::string label=std::string(labels[i])+std::string(15-std::strlen(labels[i]),' ');std::copy(label.begin(),label.end(),b.begin()+p+16);p+=block_size(i,version);}
    put(b,32,static_cast<Word>(count));Archive a(std::move(b),version);
    constexpr std::pair<unsigned,Word> defaults[]={{18,800},{19,600},{20,16},{24,30},{25,70},{26,60},{27,80},{28,60},{29,80},{30,70},{31,80},{32,1},{33,1},{34,2},{44,90},{45,90},{46,90},{47,90},{48,1},{49,1},{50,1},{51,1},{53,90},{54,1},{55,50},{484,2},{486,2},{492,90},{493,1}};
    for(auto f:defaults)a.word(1,f.first,f.second);
    constexpr nnn::Byte font[]={0x82,0x6c,0x82,0x72,32,0x83,0x53,0x83,0x56,0x83,0x62,0x83,0x4e};std::copy(std::begin(font),std::end(font),a.bytes.begin()+a.at(1)+64*4);return a;
}
struct Layout {
    fs::path original,target;std::string filename;int version=0;unsigned scripts=2,albums=20,message_stride=131072,film_stride=65536,cg_stride=512,movie_stride=384;
    bool results=false,legacy=false;std::size_t seen=0,roads=0;std::string chart_error;
    Layout(GameSession& game,const fs::path& root,const fs::path& writable,const ProgressOptions& options) {
        original=named(root,"sav");target=writable.empty()?original:writable/"systemnnn";
        filename=nnn::game_config::ascii_lower(options.system_filename);
        if(filename.empty()) {const auto format=game.pc_system_save_format();version=format[0];if(version<1||version>3||(format[1]!=0&&format[1]!=1))invalid("Unresolved PC system save filename");
            filename=std::string(format[1]?"tsysfile":"sysfile")+(version==1?"":std::to_string(version))+".sav";
        } else {for(int v=1;v<=3;++v)for(const auto* stem:{"sysfile","tsysfile"})if(filename==std::string(stem)+(v==1?"":std::to_string(v))+".sav")version=v;
            if(!version)invalid("Unsupported PC system save filename");}
        const nnn::game_config::NameListSetup config(nnn::game_config::read(root,"init","game.xtx"));results=config.integer("resultFlag",0)!=0;
        const auto project_path=nnn::game_config::find(root,"spt","project.xtx");
        if(config.integer("noScriptFlag",0)==0 && !project_path.empty()) {
            const auto project=nnn::game_config::read_text(project_path);if(project.find('\0')!=std::string::npos)invalid("Invalid project list");std::size_t cursor=0;unsigned count=0;
            while(nnn::game_config::name_token(project,cursor)) {if(++count>65536)invalid("Project list exceeds limit");}scripts=std::clamp(count?count:64U,2U,256U);
        }
        unsigned slots=2;while(slots<scripts)slots*=2;message_stride=262144/slots;film_stride=131072/slots;
        unsigned count=0;for(unsigned i=1;i<=256;++i) {std::string suffix;if(i<100)suffix=std::string(i<10?"0":"")+std::to_string(i);else {suffix.push_back(static_cast<char>('A'+(i-100)/10));suffix+=std::to_string(i%10);}
            if(nnn::game_config::find(root,"spt","cglist"+suffix+".xtx").empty())break;
            ++count;}
        albums=count?count:20;slots=albums;if(slots>2){slots=5;while(slots<albums)slots*=2;}cg_stride=slots==1?8192:slots==2?4096:10240/slots;movie_stride=256/albums*32;
        legacy=game.legacy_chart();
        // The graph's native configuration owns both standard and legacy extents.
        try {
            const nnn::chart::Graph graph(root,800,600,{},legacy?nnn::chart::Variant::LegacyChart:nnn::chart::Variant::SelectChart);
            if(graph.configured()) {const auto defaults=graph.global_defaults();seen=defaults.seen.size();roads=defaults.traversed.size();}
        } catch(const std::exception& e) {chart_error=e.what();}
    }
    fs::path source(const std::string& name)const {const auto local=named(target,name);if(fs::symlink_status(local).type()!=fs::file_type::not_found)return local;return named(original,name);}
    fs::path destination(const std::string& name)const{return named(target,name);}
    int read_bit(Word key)const {const auto script=key>>16,serial=key&0xffffU;return script<scripts&&serial<message_stride&&serial!=0xffffU?static_cast<int>(script*message_stride+serial):-1;}
    int gallery_bit(Word key)const {const auto kind=key>>28,group=(key>>16)&0xfffU,index=key&0xffffU;
        switch(kind) {case 1:return group<albums&&index<cg_stride?static_cast<int>(group*cg_stride+index):-1;
        case 2:return group<scripts&&index<film_stride?static_cast<int>(group*film_stride+index):-1;
        case 3:return group==0&&index<256?static_cast<int>(index):-1;
        case 4:return group==0&&index+1<movie_stride?static_cast<int>(index+1):-1;
        case 5:return group<1024&&index<32?static_cast<int>(group*32+index):-1;default:return -1;}}
    fs::path chart_source(const char* name)const {const auto dir=legacy?named(target,"mushiex"):target;const auto local=named(dir,name);if(fs::symlink_status(local).type()!=fs::file_type::not_found)return local;return named(legacy?named(original,"mushiex"):original,name);}
    fs::path chart_destination(const char* name)const{return named(legacy?named(target,"mushiex"):target,name);}
};

struct State {
    std::vector<Word> read,gallery;nnn::SystemVariables variables{};nnn::ScriptProgress results{};nnn::RuntimeTextState text;nnn::RuntimeOptionalProgress optional;Bytes chart;
    // Modified UTF-8 strings are retained verbatim; this bridge cannot resolve legacy textual read identities.
    std::vector<Bytes> legacy;bool has_variables=false,has_results=false,has_extension=false;
};
Bytes chart_bytes(const nnn::chart::Progress& p) {Bytes b(8);put(b,0,static_cast<Word>(p.seen.size()));put(b,4,static_cast<Word>(p.traversed.size()));b.insert(b.end(),p.seen.begin(),p.seen.end());b.insert(b.end(),p.traversed.begin(),p.traversed.end());return b;}
nnn::chart::Progress decode_chart(const Bytes& b) {
    if(b.size()<8||b.size()>8+2*max_chart)invalid("Invalid chart progress length");
    const auto seen=le(b,0),roads=le(b,4);
    if(roads<1||roads>max_chart||(seen!=((roads+3)&~Word{3}) && !(roads==10000&&seen==10004))||b.size()!=8U+seen+roads)invalid("Invalid chart progress extents");
    return {Bytes(b.begin()+8,b.begin()+8+seen),Bytes(b.begin()+8+seen,b.end())};
}
State snapshot(nnn::RuntimeContext& runtime) {
    State s;s.read=runtime.snapshot_read();s.gallery=runtime.snapshot_gallery();s.variables=runtime.system_variables();s.results=runtime.script_progress();s.text=runtime.runtime_text();s.optional=runtime.optional_progress();
    if(const auto p=runtime.chart_progress())s.chart=chart_bytes(*p);
    s.has_variables=s.has_results=s.has_extension=true;return s;
}
Bytes encode_base(const State& s) {Bytes b;be(b,0x4e4e5234);be(b,static_cast<Word>(s.read.size()));for(auto w:s.read)be(b,w);for(auto w:s.variables)be(b,static_cast<Word>(w));for(auto w:s.results)be(b,static_cast<Word>(w));be(b,static_cast<Word>(s.legacy.size()));for(const auto& raw:s.legacy){be(b,static_cast<Word>(raw.size()),2);b.insert(b.end(),raw.begin(),raw.end());}return b;}
State decode_base(const Bytes& b) {
    Reader r{b};const auto version=r.get();if(version<0x4e4e5231||version>0x4e4e5234)invalid("Unknown global progress version");
    auto count=r.get();if(count>nnn::RuntimeContext::max_read_messages)invalid("Invalid read progress count");State s;
    if(version>=0x4e4e5232)for(Word i=0;i<count;++i)s.read.push_back(r.get());
    if(version>=0x4e4e5233){for(auto& w:s.variables)w=signed_word(r.get());s.has_variables=true;}
    if(version>=0x4e4e5234){for(auto& w:s.results)w=signed_word(r.get());s.has_results=true;}
    if(version>=0x4e4e5232)count=r.get();
    if(count>nnn::RuntimeContext::max_read_messages)invalid("Invalid legacy read progress count");
    for(Word i=0;i<count;++i) {const auto n=r.get(2);auto raw=r.take(n);
        // DataInputStream.readUTF's modified UTF-8 accepts 1/2/3-byte code units only.
        for(std::size_t p=0;p<raw.size();) {const auto c=raw[p++];if(c<128)continue;const unsigned tail=(c&0xe0)==0xc0?1:(c&0xf0)==0xe0?2:99;if(tail>raw.size()-p)invalid("Malformed legacy modified UTF-8");for(unsigned j=0;j<tail;++j)if((raw[p++]&0xc0)!=0x80)invalid("Malformed legacy modified UTF-8");}
        s.legacy.push_back(std::move(raw));}
    r.end();return s;
}
void extension_record(Bytes& b,const std::array<nnn::Byte,32>& hash,const State& s) {
    b.insert(b.end(),hash.begin(),hash.end());
    const auto text=[&](const std::string& value) {b.push_back(static_cast<nnn::Byte>(value.size()));b.insert(b.end(),value.begin(),value.end());};text(s.text.surname);text(s.text.given_name);for(const auto& t:s.text.system_replacements)text(t);
    std::vector<std::pair<unsigned,Word>> words;unsigned i=0;for(auto w:s.optional.terms){if(w)words.emplace_back(i,w);++i;}for(auto w:s.optional.voice_words){if(w)words.emplace_back(i,w);++i;}for(auto w:s.optional.voice_role_words){if(w)words.emplace_back(i,w);++i;}
    be(b,static_cast<Word>(words.size()),2);for(auto w:words){be(b,w.first,2);be(b,w.second);}be(b,static_cast<Word>(s.chart.size()));b.insert(b.end(),s.chart.begin(),s.chart.end());
}
bool decode_extension(const Bytes& b,const std::array<nnn::Byte,32>& hash,State& target) {
    Reader r{b};const auto version=r.get();if(version<0x4e4e4531||version>0x4e4e4533)invalid("Unknown global progress extension");const auto count=r.get(1);if(count<1||count>2)invalid("Invalid extension generation count");
    std::optional<State> matched;
    for(Word entry=0;entry<count;++entry) {
        const auto fingerprint=r.take(32);State s;
        auto text=[&](std::size_t limit) {const auto n=r.get(1);if(n>limit)invalid("Invalid global text length");const auto raw=r.take(n);if(std::find(raw.begin(),raw.end(),0)!=raw.end())invalid("Embedded global text terminator");return std::string(raw.begin(),raw.end());};
        s.text.surname=text(15);s.text.given_name=text(15);for(auto& t:s.text.system_replacements)t=text(32);
        const auto entries=r.get(2),limit=1024U+16384U+(version==0x4e4e4533?8U:0U);if(entries>limit)invalid("Invalid optional progress count");Word previous=0;
        for(Word j=0;j<entries;++j) {const auto index=r.get(2),value=r.get();if(index>=limit||(j && index<=previous)||!value)invalid("Invalid optional progress entry");previous=index;
            if(index<1024)s.optional.terms[index]=value;else if(index<17408)s.optional.voice_words[index-1024]=value;else s.optional.voice_role_words[index-17408]=value;}
        if(version!=0x4e4e4531) {const auto size=r.get();if(size>8+2*max_chart)invalid("Chart sidecar exceeds limit");s.chart=r.take(size);if(size)decode_chart(s.chart);}
        if(std::equal(fingerprint.begin(),fingerprint.end(),hash.begin())){if(matched)invalid("Duplicate extension generation");matched=std::move(s);}
    }
    r.end();if(!matched)return false;target.text=matched->text;target.optional=matched->optional;target.chart=std::move(matched->chart);target.has_extension=true;return true;
}
bool valid_gallery(Word key) {const auto kind=key>>28;return kind>=1&&kind<=5&&(kind!=3||(key&0xfffffffU)<256)&&(kind!=4||(key&0xfffffffU)<4096)&&(kind!=5||(((key>>16)&0xfffU)<1024&&(key&0xffffU)<32));}
std::vector<Word> decode_gallery(const Bytes& b) {
    Reader r{b};if(r.get()!=0x4e4e4731)invalid("Invalid gallery progress version");const auto count=r.get();if(count>nnn::RuntimeContext::max_gallery_unlocks)invalid("Invalid gallery progress count");std::vector<Word> keys;
    for(Word i=0;i<count;++i){const auto key=r.get();if(!valid_gallery(key)||(i && key<=keys.back()))invalid("Invalid gallery progress key");keys.push_back(key);}r.end();return keys;
}
Bytes encode_gallery(const std::vector<Word>& keys){Bytes b;be(b,0x4e4e4731);be(b,static_cast<Word>(keys.size()));for(auto key:keys)be(b,key);return b;}
struct Saved {State state;Bytes bytes;fs::path source;};
std::optional<Saved> saved_base(const Layout& l,Warnings& warnings) {
    const auto primary=l.source("emberfall.read");std::optional<Saved> saved;
    guarded(warnings,"Global progress",[&]{if(auto b=read_file(primary))saved=Saved{decode_base(*b),*b,primary};});
    if(!saved) {auto backup=primary;backup+=".bak";guarded(warnings,"Global progress backup",[&]{if(auto b=read_file(backup)){saved=Saved{decode_base(*b),*b,backup};warnings.push_back("Loaded global progress backup; primary remains preserved");}});}
    if(saved) {
        const auto hash=sha256(saved->bytes);const auto ext=l.source("emberfall.read.ext");bool found=false;
        guarded(warnings,"Global progress extension",[&]{if(auto b=read_file(ext,2U*1024U*1024U))found=decode_extension(*b,hash,saved->state);});
        if(!found){auto backup=ext;backup+=".bak";guarded(warnings,"Global progress extension backup",[&]{if(auto b=read_file(backup,2U*1024U*1024U))decode_extension(*b,hash,saved->state);});}
        if(!saved->state.legacy.empty())warnings.push_back("Legacy textual read identities retained; native runtime cannot resolve them");
    }
    return saved;
}
void apply_state(nnn::RuntimeContext& runtime,const State& s) {
    if(!runtime.restore_read(s.read))invalid("Native read progress capacity exceeded");
    if(s.has_variables)runtime.set_system_variables(s.variables);
    if(s.has_results)runtime.set_script_progress(s.results);
    if(s.has_extension) {if(!runtime.restore_runtime_text(s.text,true))invalid("Native text progress rejected");runtime.restore_optional_progress(s.optional);}
}
void restore_archive(nnn::RuntimeContext& runtime,const Layout& l,const Archive& a,bool live) {
    auto s=snapshot(runtime);std::vector<Word> read;
    for(std::size_t bit=0;bit<l.scripts*l.message_stride;++bit)if(a.bit(5,bit)){const auto serial=bit%l.message_stride;if(serial<0xffff)read.push_back(static_cast<Word>((bit/l.message_stride<<16)|serial));}
    for(auto key:s.read)if(l.read_bit(key)<0||(!live&&!a.bit(5,static_cast<unsigned>(l.read_bit(key)))))read.push_back(key);
    if(!runtime.restore_read(read))invalid("Merged read progress exceeds capacity");
    std::vector<Word> gallery;
    const auto append=[&](unsigned code,unsigned kind,unsigned stride,unsigned groups) {const auto capacity=(le(a.bytes,a.at(code))-32)*8;for(std::size_t bit=0;bit<std::min<std::size_t>(capacity,static_cast<std::size_t>(stride)*groups);++bit)if(a.bit(code,bit))gallery.push_back((kind<<28)|static_cast<Word>((bit/stride<<16)|(bit%stride)));};
    append(7,1,l.cg_stride,l.albums);append(9,2,l.film_stride,l.scripts);
    for(unsigned i=0;i<256;++i)if(signed_word(a.word(12,8+i))>0)gallery.push_back((3U<<28)|i);
    for(unsigned i=1;i<l.movie_stride && i<=4096;++i)if(a.bit(11,i))gallery.push_back((4U<<28)|(i-1));
    if(a.has(18))append(18,5,32,1024);
    for(auto key:s.gallery)if(!live||l.gallery_bit(key)<0||((key>>28)==5&&!a.has(18)))gallery.push_back(key);
    if(!runtime.replace_gallery(gallery))invalid("Merged gallery progress exceeds capacity");
    if(!live)return;
    for(std::size_t i=0;i<(l.version==1?100U:1000U);++i)s.variables[i]=signed_word(a.word(6,8+i));
    runtime.set_system_variables(s.variables);
    s.text.surname=a.text(a.at(1)+56*4,15);s.text.given_name=a.text(a.at(1)+60*4,15);
    if(a.has(13))for(std::size_t i=0;i<100;++i)s.text.system_replacements[i]=a.text(a.payload(13)+i*64,32);
    if(!runtime.restore_runtime_text(s.text,true))invalid("PC runtime text rejected");
    if(a.has(14)){for(unsigned i=0;i<1024;++i)s.results[1024+i]=signed_word(a.word(14,8+i));runtime.set_script_progress(s.results);}
    if(a.has(15))for(unsigned i=0;i<1024;++i)s.optional.terms[i]=a.word(15,8+i);
    if(a.has(16))for(unsigned i=0;i<16384;++i)s.optional.voice_words[i]=a.word(16,8+i);
    s.optional.voice_role_words.fill(0);for(unsigned i=1;i<256;++i)if(a.word(10,8+i))s.optional.voice_role_words[i/32]|=Word{1}<<(i%32);runtime.restore_optional_progress(s.optional);
    runtime.with_parameters([&](nnn::RuntimeParameters& p){for(auto f:fields)if(f.second>0||a.has(17))p.set(f.first,signed_word(a.word(f.second<0?17:1,static_cast<unsigned>(std::abs(f.second)))));
        for(unsigned i=0;i<16;++i){p.set(300+i,signed_word(a.word(1,448+i)));p.set(400+i,signed_word(a.word(1,464+i)));}
        for(unsigned i=0;i<72;++i)p.set(500+i,static_cast<Value>((a.word(1,356+i/6)>>((i%6)*5))&31));});
    std::array<Word,32> off{};for(unsigned i=0;i<32;++i)off[i]=a.word(1,384+i);runtime.set_voice_off(off);runtime.set_message_window(signed_word(a.word(1,480)));
    if(a.has(17))runtime.set_system_voice_selection(signed_word(a.word(17,14)));
    // Message cursor has no dedicated raw setter: restore its configured radio binding when available.
    const nnn::game_config::NameListSetup config(nnn::game_config::read(runtime.root(),"init","game.xtx"));const auto binding=config.integer("expModeButtonIsMessageCursor",0);
    if(binding>=1&&binding<=16)runtime.set_system_parameter(300+static_cast<Word>(binding-1),signed_word(a.word(1,481)));
    runtime.set_pc_display_options(a.word(1,38)!=0,signed_word(a.word(1,482)));
}
void update_archive(Archive& a,const Layout& l,const State& s,nnn::RuntimeContext& runtime) {
    for(auto key:s.read){const auto bit=l.read_bit(key);if(bit>=0)a.set_bit(5,static_cast<unsigned>(bit));}
    for(auto key:s.gallery) {const auto bit=l.gallery_bit(key);if(bit<0)continue;switch(key>>28) {case 1:a.set_bit(7,bit);break;case 2:a.set_bit(9,bit);break;case 3:if(signed_word(a.word(12,8+bit))<=0)a.word(12,8+bit,1);break;case 4:a.set_bit(11,bit);break;case 5:if(a.has(18))a.set_bit(18,bit);break;default:break;}}
    for(unsigned i=0;i<(l.version==1?100U:1000U);++i)a.word(6,8+i,static_cast<Word>(s.variables[i]));
    if(a.has(14))for(unsigned i=0;i<1024;++i)a.word(14,8+i,static_cast<Word>(s.results[1024+i]));
    a.text(a.at(1)+56*4,16,15,s.text.surname);a.text(a.at(1)+60*4,16,15,s.text.given_name);
    if(a.has(13))for(unsigned i=0;i<100;++i)a.text(a.payload(13)+i*64,64,32,s.text.system_replacements[i]);
    if(a.has(15))for(unsigned i=0;i<1024;++i)a.word(15,8+i,s.optional.terms[i]);
    if(a.has(16))for(unsigned i=0;i<16384;++i)a.word(16,8+i,s.optional.voice_words[i]);
    for(unsigned i=1;i<256;++i)if(s.optional.voice_role_heard(static_cast<Value>(i))&&!a.word(10,8+i))a.word(10,8+i,1);
    const auto parameters=runtime.snapshot_parameters();for(auto f:fields)if(f.second>0||a.has(17))a.word(f.second<0?17:1,static_cast<unsigned>(std::abs(f.second)),static_cast<Word>(parameters.get(f.first)));
    for(unsigned i=0;i<16;++i){a.word(1,448+i,static_cast<Word>(parameters.get(300+i)));a.word(1,464+i,static_cast<Word>(parameters.get(400+i)));}
    for(unsigned i=0;i<72;++i){const auto shift=(i%6)*5;a.word(1,356+i/6,(a.word(1,356+i/6)&~(Word{31}<<shift))|((static_cast<Word>(parameters.get(500+i))&31)<<shift));}
    const auto off=runtime.voice_off();for(unsigned i=0;i<32;++i)a.word(1,384+i,off[i]);a.word(1,480,static_cast<Word>(runtime.message_window()));
    const auto cursors=runtime.cursor_variants();
    const nnn::game_config::NameListSetup config(nnn::game_config::read(runtime.root(),"init","game.xtx"));
    const auto binding=config.integer("expModeButtonIsMessageCursor",0);
    // Without a raw native setter, retain an imported cursor that the runtime
    // cannot faithfully restore instead of replacing it with a default zero.
    if((binding>=1&&binding<=16)||cursors[0]!=0)a.word(1,481,static_cast<Word>(cursors[0]));
    a.word(1,482,static_cast<Word>(cursors[1]));a.word(1,38,runtime.no_skip_frame()?1:0);
    if(a.has(17))a.word(17,14,static_cast<Word>(runtime.system_voice_selection()));
}
void write_if_changed(const fs::path& path,const Bytes& bytes,std::size_t limit=max_file) {const auto old=read_file(path,limit);if(!old||*old!=bytes)atomic_write(path,bytes);}
} // namespace

std::vector<std::string> load_progress(GameSession& game,const fs::path& root,const fs::path& writable,const ProgressOptions& options) {
    Warnings warnings;
    guarded(warnings,"Progress configuration",[&]{
        const Layout l(game,root,writable,options);
        if(!l.chart_error.empty())warnings.push_back("Chart configuration: "+l.chart_error);
        auto runtime=game.runtime();
        const auto base=saved_base(l,warnings);if(base)guarded(warnings,"Global progress restore",[&]{apply_state(*runtime,base->state);});
        guarded(warnings,"Gallery progress",[&]{if(auto b=read_file(l.source("emberfall.gallery")))if(!runtime->merge_gallery(decode_gallery(*b)))invalid("Gallery capacity exceeded");});
        guarded(warnings,"PC global progress",[&]{auto b=read_file(l.source(l.filename),max_pc);bool live=b.has_value();
            if(!b){const auto factory=l.filename.substr(0,l.filename.size()-4)+".org";b=read_file(named(l.original,factory),max_pc);}
            if(b) {
                const Archive archive(std::move(*b),l.version);
                restore_archive(*runtime,l,archive,live);
                const nnn::game_config::NameListSetup config(nnn::game_config::read(root,"init","game.xtx"));
                const auto binding=config.integer("expModeButtonIsMessageCursor",0);
                if(live&&(binding<1||binding>16)&&archive.word(1,481)!=0)
                    warnings.push_back("PC message cursor retained on disk; native RuntimeContext cannot restore it without a configured radio binding");
            }});
        if(l.results)guarded(warnings,"PC results",[&]{if(auto b=read_file(l.source("result.sav"),4096)){if(b->size()!=4096)invalid("Invalid PC result length");auto result=runtime->script_progress();for(unsigned i=0;i<1024;++i)result[i]=signed_word(le(*b,i*4));runtime->set_script_progress(result);}});
        guarded(warnings,"Chart progress",[&]{
            std::optional<nnn::chart::Progress> progress;if(base&&!base->state.chart.empty())progress=decode_chart(base->state.chart);
            if(l.roads) {
                auto seen=read_file(l.chart_source("mita.dat"),max_chart),roads=read_file(l.chart_source("tsuka.dat"),max_chart);
                if(seen&&seen->size()!=l.seen)invalid("Invalid PC chart seen length");
                if(roads&&roads->size()!=l.roads)invalid("Invalid PC chart road length");
                if(seen||roads){if(!progress)progress=nnn::chart::Progress{Bytes(l.seen),Bytes(l.roads)};if(seen)progress->seen=std::move(*seen);if(roads)progress->traversed=std::move(*roads);}
            }
            if(progress&&!game.restore_chart_progress(std::move(*progress)))invalid("Chart progress does not match native graph");
        });
        game.sync_runtime_names();game.apply_runtime_parameters();
    });return warnings;
}
std::vector<std::string> save_progress(GameSession& game,const fs::path& root,const fs::path& writable,const ProgressOptions& options) {
    Warnings warnings;
    guarded(warnings,"Progress configuration",[&]{
        const Layout l(game,root,writable,options);
        if(!l.chart_error.empty())warnings.push_back("Chart configuration: "+l.chart_error);
        auto runtime=game.runtime();auto s=snapshot(*runtime);
        guarded(warnings,"Global progress",[&]{
            // Never replace malformed primary or extension files, including imported originals.
            const auto old=read_file(l.source("emberfall.read"));std::optional<State> previous;
            if(old)previous=decode_base(*old);
            const auto ext=read_file(l.source("emberfall.read.ext"),2U*1024U*1024U);
            if(ext){State unused;decode_extension(*ext,old?sha256(*old):std::array<nnn::Byte,32>{},old?*previous:unused);}
            if(previous)s.legacy=previous->legacy;
            const auto next=encode_base(s);if(next.size()>max_file)invalid("Global progress exceeds size limit");Bytes extension;be(extension,0x4e4e4533);extension.push_back(previous&&previous->has_extension&&*old!=next?2:1);extension_record(extension,sha256(next),s);
            if(previous&&previous->has_extension&&*old!=next)extension_record(extension,sha256(*old),*previous);
            // Publish both generations first. Either base remains paired after a crash.
            write_if_changed(l.destination("emberfall.read.ext"),extension,2U*1024U*1024U);write_if_changed(l.destination("emberfall.read"),next);
            if(!s.legacy.empty())warnings.push_back("Legacy textual read identities retained; native runtime cannot resolve them");
        });
        guarded(warnings,"Gallery progress",[&]{if(auto b=read_file(l.source("emberfall.gallery")))decode_gallery(*b);write_if_changed(l.destination("emberfall.gallery"),encode_gallery(s.gallery));});
        guarded(warnings,"PC global progress",[&]{
            auto b=read_file(l.source(l.filename),max_pc);const bool fresh=!b;
            if(!b){const auto factory=l.filename.substr(0,l.filename.size()-4)+".org";guarded(warnings,"PC factory defaults",[&]{if(auto defaults=read_file(named(l.original,factory),max_pc)){Archive checked(*defaults,l.version);b=std::move(defaults);}});}
            auto a=b?Archive(std::move(*b),l.version):create_archive(l.version);const auto before=a.bytes;update_archive(a,l,s,*runtime);
            if(fresh||a.bytes!=before||l.source(l.filename)!=l.destination(l.filename)){a.stamp();write_if_changed(l.destination(l.filename),a.bytes,max_pc);}
            if(!a.has(17))warnings.push_back("PC archive has no SYSTEMFLAG2: script-SE/continuation settings and system voice theme are not representable");
            const nnn::game_config::NameListSetup config(nnn::game_config::read(root,"init","game.xtx"));const auto binding=config.integer("expModeButtonIsMessageCursor",0);
            if((binding<1||binding>16)&&runtime->cursor_variants()[0]!=0)warnings.push_back("Message cursor is written to PC archive, but native RuntimeContext has no raw restore setter without its configured radio binding");
        });
        if(l.results)guarded(warnings,"PC results",[&]{if(auto old=read_file(l.source("result.sav"),4096))if(old->size()!=4096)invalid("Invalid PC result length");Bytes b(4096);for(unsigned i=0;i<1024;++i)put(b,i*4,static_cast<Word>(s.results[i]));write_if_changed(l.destination("result.sav"),b,4096);});
        if(!s.chart.empty())guarded(warnings,"PC chart progress",[&]{const auto p=decode_chart(s.chart);if(p.seen.size()!=l.seen||p.traversed.size()!=l.roads)invalid("Chart progress does not match PC graph");
            const auto write=[&](const char* name,const Bytes& b){if(auto old=read_file(l.chart_source(name),max_chart))if(old->size()!=b.size())invalid("Invalid existing PC chart length");write_if_changed(l.chart_destination(name),b,max_chart);};write("mita.dat",p.seen);write("tsuka.dat",p.traversed);});
    });return warnings;
}
} // namespace aether::systemnnn
