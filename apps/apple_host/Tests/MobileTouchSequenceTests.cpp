#include "../IOSHost/TouchSequence.h"
#include <cassert>
#include <iostream>
int main() {
    using aether::mobile::TouchSequence;
    TouchSequence sequence;
    assert(sequence.begin(1)); assert(!sequence.begin(2));
    sequence.finish(1,true); assert(!sequence.begin(2));
    sequence.finish(1,false); assert(!sequence.begin(1));
    sequence.finish(0,false); assert(sequence.begin(1));
    sequence.cancel(); assert(!sequence.begin(1));
    sequence.finish(0,false); assert(sequence.begin(1));
    sequence.reject(); assert(!sequence.begin(1));
    sequence.finish(0,false); sequence.cancel(); assert(sequence.begin(1));
    sequence.finish(0,true); assert(sequence.begin(1));
    sequence.begin(2); sequence.finish(1,false); assert(sequence.captured);
    sequence.finish(0,true); assert(!sequence.captured && !sequence.waiting);
    assert(!sequence.begin(2)); sequence.finish(0,false); assert(sequence.begin(1));
    std::cout << "PASS mobile touch sequence: secondary rejection, all-lift barrier, cancel, black-edge rejection\n";
}
