#!/usr/bin/env python3
"""Cross-check native fixtures with the unmodified Android Java readers.

Usage: python3 check_progress_java.py PATH_TO_SYSTEMNNN_EMBERFALL NATIVE_TEST_BINARY
The standalone C++ test binary accepts an output directory to export fixtures.
Only Java host/Android environment dependencies are stubbed; the three format
readers come directly from the sibling checkout.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

STUBS = r'''
package com.tyranor.runtime.systemnnn;
import java.io.*;
import java.util.*;
class NativeGame {
 static final int SYSTEM_VARIABLES=1000,SCRIPT_PROGRESS=2048;
 static final int LEGACY_OPTIONAL_PROGRESS_WORDS=17408,OPTIONAL_PROGRESS_WORDS=17416;
}
class GameUiAssets {static class Config {int number(String key,int fallback){return fallback;}}}
class GameResourcePaths {
 static File file(File root,String... parts){File f=root;for(String p:parts)f=new File(f,p);return f.isFile()?f:null;}
 static File directory(File root,String name){File f=new File(root,name);return f.isDirectory()?f:null;}
}
class GalleryCatalog {static List<String> tokens(File root,String folder,String name){return Collections.emptyList();}}
'''
ATOMIC = r'''
package android.util;
import java.io.*;
public class AtomicFile {
 private final File file;
 public AtomicFile(File file){this.file=file;}
 public File getBaseFile(){return file;}
 public FileInputStream openRead()throws IOException{return new FileInputStream(file);}
 public FileOutputStream startWrite()throws IOException{return new FileOutputStream(file);}
 public void finishWrite(FileOutputStream out)throws IOException{out.close();}
 public void failWrite(FileOutputStream out)throws IOException{out.close();}
}
'''
CHECK = r'''
package com.tyranor.runtime.systemnnn;
import java.io.*;
import java.nio.file.*;
import java.util.*;
public class Check {
 static void require(boolean b,String s){if(!b)throw new AssertionError(s);}
 public static void main(String[] args)throws Exception{
  File root=new File(args[0]);
  for(String name:new String[]{"sysfile.sav","sysfile2.sav","sysfile3.sav"})
   require(PcSystemSave.valid(new File(root,name)),"PC block layout "+name);
  GameProgress.State s=new GameProgress(new File(root,"emberfall.read")).read();
  require(Arrays.equals(s.read,new int[]{1,0x12340002}),"read flags");
  require(s.variables[999]==-123&&s.results[1029]==100,"variables/results");
  require(new String(s.text[0],"US-ASCII").equals("Last")&&new String(s.text[5],"US-ASCII").equals("replacement"),"text generation/SHA-256");
  require(s.optional[7]==3&&s.optional[1024+15625]==1&&s.optional[17415]==0x80000000,"optional progress");
  require(s.chart.length==15&&s.chart[0]==4&&s.chart[4]==3,"chart layout");
  require(Arrays.equals(new GalleryStore(new File(root,"emberfall.gallery")).read(),new int[]{0x10010003,0x30000001,0x50020003}),"gallery keys");
  ByteArrayOutputStream out=new ByteArrayOutputStream();GameProgress.encode(new DataOutputStream(out),s);
  require(Arrays.equals(out.toByteArray(),Files.readAllBytes(new File(root,"emberfall.read").toPath())),"Java re-encoded NNR4 matches native bytes");
  System.out.println("Original Java readers accepted native PC/NNR4/NNE3/NNG1 fixtures");
 }
}
'''

def main():
    source=pathlib.Path(sys.argv[1]).resolve()/"platform/android/player/java"
    binary=pathlib.Path(sys.argv[2]).resolve()
    with tempfile.TemporaryDirectory(prefix="systemnnn-java-check-") as tmp:
        root=pathlib.Path(tmp)
        subprocess.run([str(binary),str(root/"fixtures")],check=True)
        java=root/"src/com/tyranor/runtime/systemnnn"
        java.mkdir(parents=True)
        for name in ("PcSystemSave.java","GameProgress.java","GalleryStore.java"):
            shutil.copyfile(source/name,java/name)
        (java/"Stubs.java").write_text(STUBS)
        (java/"Check.java").write_text(CHECK)
        android=root/"src/android/util"
        android.mkdir(parents=True)
        (android/"AtomicFile.java").write_text(ATOMIC)
        sources=[str(p) for p in (root/"src").rglob("*.java")]
        subprocess.run(["javac","-encoding","UTF-8","-d",str(root/"classes"),*sources],check=True)
        subprocess.run(["java","-cp",str(root/"classes"),"com.tyranor.runtime.systemnnn.Check",str(root/"fixtures")],check=True)

if __name__=="__main__":
    main()
