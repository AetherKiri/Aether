#!/usr/bin/env python3
"""Compare deterministic portable board traces with the unmodified Android board.
Usage: check_minigame_java.py EMBERFALL_ROOT MINIGAME_CONTRACT_EXECUTABLE
The executable's --trace mode emits 49,045 complete public-state observations, including rare animation fixtures.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

HARNESS = r'''
package com.tyranor.runtime.systemnnn;
import java.util.Random;
final class MiniGameParity {
    static void vector(int[] v) {if(v!=null)for(int x:v)System.out.print(x+",");System.out.print(";");}
    static void state(MiniGameBoard b) {
        int[] head={b.type,b.columns,b.rows,b.selected,b.held,b.hintLeft,b.cleared?1:0,b.gameOver?1:0,b.animation.ordinal(),b.frame,b.frameLimit,b.firstDealt,b.turningCard,b.hintAlpha()};
        for(int n:head)System.out.print(n+",");System.out.print(";");
        vector(b.cells);vector(b.dealOrder);
        for(int n:b.stock)System.out.print(n+",");System.out.print(";");
        for(int n:b.waste)System.out.print(n+",");System.out.print(";");
        vector(b.movingTo);vector(b.erasing);vector(b.connection);vector(b.incoming);
        for(int n=0;n<b.cells.length;n++)System.out.print(b.hinted(n)?"1":"0");
        String sound=b.takeSound();System.out.println(";"+(sound==null?"":sound));
    }
    public static void main(String[] args) {
        for(int type=1;type<=10;type++)for(long seed:new long[]{0,1,42,987654321}) {
            MiniGameBoard b=new MiniGameBoard(type,new Random(seed),16,16);int op=(int)seed+123;state(b);
            for(int n=0;n<1200;n++) {
                op=op*1664525+1013904223;int which=(op>>>24)%9;
                if(which<3)b.choose((op>>>8)%148-3);
                else if(which==3)b.drawStock();else if(which==4)b.showHint();else if(which==5)b.dismissHint();
                else if(which==6)b.pressDuringAnimation();else {int ticks=(op>>>8)%31;while(ticks-->0)b.advanceAnimation();}
                state(b);
            }
        }
        for(int type=6;type<=10;type++) {
            MiniGameBoard b=new MiniGameBoard(type,new Random(42),16,16);
            java.util.Arrays.fill(b.cells,-1);b.stock.clear();b.waste.clear();b.animation=MiniGameBoard.Animation.NONE;
            if(type==6){b.cells[2]=0;b.stock.addLast(1);b.stock.addLast(2);b.drawStock();}
            if(type==7){b.cells[42]=1;b.waste.addLast(3);b.waste.addLast(4);b.drawStock();}
            if(type==8){b.cells[28]=12;b.waste.addLast(0);b.choose(28);}
            if(type==9){b.cells[0]=136;b.cells[1]=137;b.cells[2]=0;b.cells[20]=1;b.choose(0);b.choose(1);}
            if(type==10){b.cells[0]=0;b.cells[1]=4;b.cells[2]=1;b.cells[3]=5;b.choose(0);b.choose(2);}
            state(b);for(int n=0;n<200;n++){b.advanceAnimation();state(b);}
        }
    }
}
'''

def main():
    root=pathlib.Path(sys.argv[1]).resolve()
    executable=pathlib.Path(sys.argv[2]).resolve()
    source=root/'platform/android/player/java/MiniGameBoard.java'
    with tempfile.TemporaryDirectory(prefix='systemnnn-minigame-java-') as tmp:
        directory=pathlib.Path(tmp)
        shutil.copyfile(source,directory/'MiniGameBoard.java')
        (directory/'MiniGameParity.java').write_text(HARNESS,encoding='utf-8')
        subprocess.run(['javac','-d',tmp,str(directory/'MiniGameBoard.java'),str(directory/'MiniGameParity.java')],check=True)
        java=subprocess.run(['java','-cp',tmp,'com.tyranor.runtime.systemnnn.MiniGameParity'],check=True,stdout=subprocess.PIPE).stdout.splitlines()
        native=subprocess.run([str(executable),'--trace'],check=True,stdout=subprocess.PIPE).stdout.splitlines()
        if len(java)!=len(native):
            raise AssertionError(f'Trace count: Java {len(java)}, native {len(native)}')
        for n,(expected,actual) in enumerate(zip(java,native)):
            if expected!=actual:
                type_id=n//(4*1201)+1
                seed_id=n//1201%4
                step=n%1201
                raise AssertionError(f'type={type_id}, seed_index={seed_id}, observation={step}\nJava: {expected.decode()}\nC++: {actual.decode()}')
        print(f'Java/C++ minigame parity PASS: {len(java)} complete state observations, ten types, four seeds')

if __name__=='__main__':
    main()
