#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

namespace aether::systemnnn::dialogue {
// Portable counterpart of Android DialogueMarkup. Offsets are Unicode scalars,
// not UTF-16 units or source bytes. Only non-newline body glyphs spend VM time.
struct Annotation {
    std::size_t start=0,end=0;
    std::u32string text;
    bool emphasis=false;
    std::size_t label_offset(std::size_t body_offset) const noexcept {
        if(body_offset<=start)return 0;
        if(body_offset>=end)return text.size();
        const auto preceding=body_offset-start,count=end-start;
        return emphasis?std::min(preceding,text.size()):(preceding*text.size()+count/2)/count;
    }
};
struct Markup {
    std::u32string text;
    std::vector<Annotation> ruby;
    std::size_t glyph_count() const noexcept {
        return static_cast<std::size_t>(std::count_if(text.begin(),text.end(),[](char32_t c){return c!=U'\r' && c!=U'\n';}));
    }
    std::size_t offset_for_glyphs(std::size_t count) const noexcept {
        std::size_t offset=0;
        while(offset<text.size()) {
            if(text[offset]!=U'\r' && text[offset]!=U'\n') {if(!count)break;--count;}
            ++offset;
        }
        return offset;
    }
};
inline std::u32string normalize(std::u32string_view source) {
    std::u32string out;out.reserve(source.size());
    for(std::size_t i=0;i<source.size();++i) {
        if(source[i]==U'\r') {out+=U'\n';if(i+1<source.size() && source[i+1]==U'\n')++i;}
        else out+=source[i];
    }
    return out;
}
inline Markup parse(std::u32string_view source,bool single_byte) {
    Markup out;
    const char32_t open=single_byte?U'[':U'［',close=single_byte?U']':U'］',em=single_byte?U'.':U'強';
    std::size_t line_start=0,annotations=0;
    for(std::size_t i=0;i<source.size();) {
        if(source[i]==U'#' && i+1<source.size()) {
            const auto command=source[i+1];
            if(command==close) {i+=2;continue;}
            if(command==open || command==em) {
                std::size_t at=i+2,count=0;
                if(command==open && at<source.size()) {
                    const auto digit=source[at++];
                    if(digit>=U'1' && digit<=U'9')count=digit-U'0';
                    else if(digit>=U'１' && digit<=U'９')count=digit-U'０';
                }
                const auto begin=at;
                while(at<source.size() && source[at]!=close && source[at]!=U'\r' && source[at]!=U'\n' && at-begin<100)++at;
                if(at<source.size() && source[at]==close && at>begin && at-begin<100 && (command==em || count)) {
                    if(command==em)count=at-begin;
                    if(count<=out.text.size()-line_start && annotations<256) {
                        out.ruby.push_back({out.text.size()-count,out.text.size(),std::u32string(source.substr(begin,at-begin)),command==em});++annotations;
                    }
                    i=at+1;continue;
                }
            }
        }
        out.text+=source[i++];
        if(out.text.back()==U'\r' || out.text.back()==U'\n'){line_start=out.text.size();annotations=0;}
    }
    return out;
}
struct Message {
    std::u32string normalized,name,body;
    std::size_t body_start=0;
};
// Name recognition is supplied by the same configured speaker palette that the
// presenter uses; no guessed punctuation or first-row heuristic is introduced.
inline Message split(std::u32string_view source,bool print,bool show_name,bool automatic,bool recognized_name) {
    Message result;result.normalized=normalize(source);
    if(print && show_name && (!automatic || recognized_name) && !result.normalized.empty()) {
        const auto end=result.normalized.find(U'\n');result.name=result.normalized.substr(0,end);
        result.body_start=end==std::u32string::npos?result.normalized.size():end+1;
    }
    result.body=result.normalized.substr(result.body_start);
    // Android's display markup removes exactly one final line break.
    if(!result.body.empty() && result.body.back()==U'\n')result.body.pop_back();
    return result;
}
inline std::size_t append_glyphs(const Message& message,std::u32string_view decoded_prefix,bool single_byte) {
    const auto prefix=normalize(decoded_prefix);
    if(prefix.empty() || prefix.size()>message.normalized.size() || message.normalized.compare(0,prefix.size(),prefix)!=0)return 0;
    const auto body_end=std::min(message.body.size(),prefix.size()>message.body_start?prefix.size()-message.body_start:0);
    return parse(std::u32string_view(message.body).substr(0,body_end),single_byte).glyph_count();
}
inline std::uint32_t native_count(std::size_t count) noexcept {
    return static_cast<std::uint32_t>(std::min(count,static_cast<std::size_t>(std::numeric_limits<std::uint32_t>::max())));
}
} // namespace aether::systemnnn::dialogue
