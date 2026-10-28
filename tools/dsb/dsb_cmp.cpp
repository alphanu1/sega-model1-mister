// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// dsb_fixmodel.h against MAME's own mpeg_audio.cpp (BSD-3, not copied here),
// decoding every song in the Z80's table from its start to its end:
//
//   M=<mame>/src/devices/sound
//   cp $M/mpeg_audio.cpp $M/mpeg_audio.h <tmp>/; sed -i s/^private:/public:/ <tmp>/mpeg_audio.h
//   (plus an emu.h that includes <cstring> <cmath> <cassert> <cstdint>)
//   g++ -O2 -std=c++20 -I<tmp> -Itools/dsb tools/dsb/dsb_cmp.cpp <tmp>/mpeg_audio.cpp
//   ./a.out mpeg.bin tools/dsb/swa_songs.txt [FS,WS,FC,FV,WV,FC1,FSC]
//
// mpeg.bin = mpr-16514.57 + mpr-16515.58 concatenated.
#include "emu.h"
#include "mpeg_audio.h"
#include "dsb_fixmodel.h"
#include <cstdio>
#include <map>
int main(int argc,char**argv){
  FILE*f=fopen(argv[1],"rb"); std::vector<uint8_t> rom(8<<20,0xff); fread(rom.data(),1,4<<20,f); fclose(f);
  FixCfg c; if(argc>3){ sscanf(argv[3],"%d,%d,%d,%d,%d,%d,%d",&c.FS,&c.WS,&c.FC,&c.FV,&c.WV,&c.FC1,&c.FSC);}
  // songs: start,end pairs from argv[2] file
  FILE*sf=fopen(argv[2],"r"); unsigned s,e; std::map<int,long> hist; long tot=0; int maxd=0; long frames=0; long offgrid=0;
  mpeg_audio ref(rom.data(), mpeg_audio::L2, false, 0);
  FixDec fx(rom.data(), c);

  while(fscanf(sf,"%x %x",&s,&e)==2){
    int p1=s*8,p2=s*8; int16_t o1[1152*2], o2[1152*2]; int n,sr,chn;
    while(true){
      bool a=ref.decode_buffer(p1,e*8,o1,n,sr,chn);
      bool b=fx.frame(p2,e*8,o2,ref.s_synthesis_filter);
      if(a!=b||p1!=p2){ printf("DIVERGE song %x: a=%d b=%d p1=%d p2=%d\n",s,a,b,p1,p2); break; }
      if(!a) break;
      frames++; if(n!=1152||chn!=2) printf("n=%d ch=%d\n",n,chn);
      for(int i=0;i<2304;i++){ int d=abs(o1[i]-o2[i]); hist[d]++; tot++; if(d>maxd)maxd=d; }
    }
  }
  printf("frames=%ld samples=%ld maxdiff=%d\n",frames,tot,maxd);
  for(auto&kv:hist) printf("  |d|=%d : %ld\n",kv.first,kv.second);
}
