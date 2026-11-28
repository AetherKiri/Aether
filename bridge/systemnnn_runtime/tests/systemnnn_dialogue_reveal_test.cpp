#include "systemnnn_dialogue_reveal.h"
#include "nnn/player_behavior.hpp"
#include <cassert>
#include <filesystem>
#include <limits>
using namespace aether::systemnnn;
int main() {
    auto m=dialogue::split(U"Alice\r\nAB#[2four]C\r\nD\r\n",true,true,false,false);
    assert(m.name==U"Alice" && m.body==U"AB#[2four]C\nD");
    const auto p=dialogue::parse(m.body,true);assert(p.text==U"ABC\nD" && p.glyph_count()==4);
    assert(p.offset_for_glyphs(0)==0 && p.offset_for_glyphs(2)==2 && p.offset_for_glyphs(3)==4 && p.offset_for_glyphs(4)==5);
    assert(p.ruby.size()==1 && p.ruby[0].label_offset(0)==0 && p.ruby[0].label_offset(1)==2 && p.ruby[0].label_offset(2)==4);
    assert(dialogue::append_glyphs(m,U"Alice\r\nAB#[2four]",true)==2);
    assert(dialogue::append_glyphs(m,U"wrong",true)==0);
    auto emphasis=dialogue::parse(U"XY#... ]",true);assert(emphasis.text==U"XY");
    assert(emphasis.ruby.empty()); // Four label glyphs cannot annotate two bases.
    emphasis=dialogue::parse(U"XY#... ]Z",true);assert(emphasis.text==U"XYZ");
    emphasis=dialogue::parse(U"XY#... ]",true);
    const auto dots=dialogue::parse(U"XY#... ]",false);assert(dots.text==U"XY#... ]");
    const auto full=dialogue::parse(U"漢字#［２かんじ］\n\U0001f600",false);
    assert(full.text==U"漢字\n\U0001f600" && full.glyph_count()==3 && full.offset_for_glyphs(2)==3);
    assert(dialogue::split(U"Alice\ntext",true,true,true,false).body==U"Alice\ntext");
    assert(dialogue::split(U"Alice\ntext",true,true,true,true).body==U"text");
    assert(dialogue::split(U"Alice\ntext",false,true,false,false).name.empty());
    assert(dialogue::native_count(std::numeric_limits<std::size_t>::max())==std::numeric_limits<std::uint32_t>::max());
    nnn::RuntimeParameters parameters;
    nnn::PlayerBehavior clock(parameters,std::filesystem::path("/tmp/systemnnn-no-such-game"));
    parameters.set(nnn::NNNPARAM_MESSAGESPEED,0);clock.begin_line(false,0);clock.set_text_length(4);
    assert(!clock.text_complete());clock.text_characters(49);assert(clock.visible_text()==0);
    clock.text_characters(1);assert(clock.visible_text()==1);
    assert(!clock.request_advance() && clock.text_complete());assert(clock.request_advance());
    parameters.set(nnn::NNNPARAM_AUTOMODE,1);clock.begin_line(true,1000);clock.set_text_length(1);
    clock.text_characters(50);assert(clock.text_complete());assert(!clock.auto_ready(50,true));
    clock.text_characters(1000);assert(!clock.auto_ready(1000,true));
    clock.text_characters(500);assert(clock.auto_ready(500,true));
    // APPEND carries already visible glyphs but restarts the source wait clock.
    clock.begin_line(false,0,0,true);clock.set_text_length(6,4);assert(clock.visible_text()==4 && !clock.text_complete());
}
