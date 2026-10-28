// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 1 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// Bit-accurate C model of the PLANNED fixed-point MPEG-1 Layer II decoder for
// Star Wars DSB (stereo, 32 kHz, 128 kbit/s, allocation table 0 -- every one of
// the 7,281 frames in mpr-16514/16515 has that header). Widths are parameters
// (FixCfg) so the M10K cost of a width can be priced against its error. The
// RTL is meant to match THIS bit for bit; this is compared against MAME below.
#include <cstdio>
// Fixed-point model of the planned Layer II decoder (format: stereo/32k/128k, table 0).
#include <cstdint>
#include <cstring>
#include <cmath>
#include <vector>
struct FixCfg { int FS=20, WS=24, FC=17, FV=17, WV=24, FC1=16, FSC=22; };
struct FixDec {
  const uint8_t *base; FixCfg c;
  int64_t V[2][512]; int vpos=0; // ring
  int cur, lim;
  struct Lim{};
  FixDec(const uint8_t*b, FixCfg cc):base(b),c(cc){ memset(V,0,sizeof V); }
  int bit(){ int v=(base[cur>>3]>>(7-(cur&7)))&1; cur++; return v; }
  int gb(int n){ if(cur+n>lim) throw Lim(); int v=0; for(int i=0;i<n;i++) v=(v<<1)|bit(); return v; }
  static int nbal(int sb){ return sb<11?4: sb<23?3: sb<27?2:0; }
  static int cls(int sb,int idx){
    if(sb<3) { static const int m[16]={0,1,3,5,6,7,8,9,10,11,12,13,14,15,16,17}; return m[idx]; }
    if(sb<11) return idx==15?17:idx;
    if(sb<23) return idx==7?17:idx;
    return idx==3?17:idx; }
  // class info: bits, grouped(cube bits), modulo, d (D*2^(b-1)), C
  static void info(int k,int&bits,int&cube,int&mod,int&d,double&C){
    static const int B[18]={0,2,3,3,4,4,5,6,7,8,9,10,11,12,13,14,15,16};
    static const int CB[18]={0,5,7,0,10,0,0,0,0,0,0,0,0,0,0,0,0,0};
    static const int MO[18]={0,3,5,7,9,15,31,63,127,255,511,1023,2047,4095,8191,16383,32767,65535};
    static const double off[18]={0,1./2,1./2,1./4,1./2,1./8,1./16,1./32,1./64,1./128,1./256,1./512,1./1024,1./2048,1./4096,1./8192,1./16384,1./32768};
    static const double r[18]={0,1-1.0/4,1-3.0/8,1-1.0/8,1-7.0/16,1-1.0/16,1-1.0/32,1-1.0/64,1-1.0/128,1-1.0/256,1-1.0/512,1-1.0/1024,1-1.0/2048,1-1.0/4096,1-1.0/8192,1-1.0/16384,1-1.0/32768,1-1.0/65536};
    bits=B[k]; cube=CB[k]; mod=MO[k]; d=(int)lround(off[k]*(1<<(bits-1))); C=1/r[k]; }
  static int64_t rnd(double x){ return llround(x); }
  static int64_t sat(int64_t x,int w){ int64_t m=(1LL<<(w-1))-1; return x>m?m:x<-m-1?-m-1:x; }
  int64_t cosq(int k){ return rnd(cos(k*M_PI/64)*(1LL<<c.FC)); }
  // returns false like MAME on limit; outputs 1152 stereo samples
  bool frame(int &pos,int limit,int16_t*out,const double*win){
    if(limit-pos<16) return false;
    cur=pos; lim=limit;
    int sync=0; for(int i=0;i<12;i++) sync=(sync<<1)|bit();
  retry:
    while(sync!=0xfff && cur<limit) sync=((sync<<1)|bit())&0xfff;
    if(limit-cur<4) return false;
    { int var=(bit()<<2); var|=bit()<<1; var|=bit(); if(var!=6){ cur-=3; sync=((sync<<1)|bit())&0xfff; goto retry; } }
    int alloc[2][32]={}, scfsi[2][32]={}, scf[2][3][32]={};
    try{
      int prot=gb(1), bri=gb(4), sr=gb(2); gb(1); gb(1); int mode=gb(2); gb(2); gb(2); gb(2); if(!prot) gb(16);
      if(bri!=8||sr!=2||mode!=0){ fprintf(stderr,"unsupported header %d %d %d at %d\n",bri,sr,mode,cur); return false; }
      for(int sb=0;sb<27;sb++) for(int ch=0;ch<2;ch++) alloc[ch][sb]=cls(sb,gb(nbal(sb)));
      for(int sb=0;sb<27;sb++) for(int ch=0;ch<2;ch++) if(alloc[ch][sb]) scfsi[ch][sb]=gb(2);
      for(int sb=0;sb<27;sb++) for(int ch=0;ch<2;ch++) if(alloc[ch][sb]) {
        int *s=&scf[ch][0][sb]; int a,b2;
        switch(scfsi[ch][sb]){
          case 0: scf[ch][0][sb]=gb(6); scf[ch][1][sb]=gb(6); scf[ch][2][sb]=gb(6); break;
          case 1: a=gb(6); scf[ch][0][sb]=scf[ch][1][sb]=a; scf[ch][2][sb]=gb(6); break;
          case 2: a=gb(6); scf[ch][0][sb]=scf[ch][1][sb]=scf[ch][2][sb]=a; break;
          case 3: scf[ch][0][sb]=gb(6); b2=gb(6); scf[ch][1][sb]=scf[ch][2][sb]=b2; break; } (void)s; }
      int o=0;
      for(int part=0;part<3;part++) for(int g=0;g<4;g++){
        int64_t Sb[2][3][32]={};
        for(int sb=0;sb<27;sb++) for(int ch=0;ch<2;ch++){
          int k=alloc[ch][sb]; if(!k) continue;
          int bits,cube,mod,d; double C; info(k,bits,cube,mod,d,C);
          int v[3];
          if(cube){ int val=gb(cube); v[0]=val%mod; val/=mod; v[1]=val%mod; val/=mod; v[2]=val%mod; }
          else { v[0]=gb(bits); v[1]=gb(bits); v[2]=gb(bits); }
          int64_t Cq=rnd(C*(1LL<<c.FC1));
          int sf=scf[ch][part][sb];
          int64_t sq = sf==63?0: rnd(pow(2.0,1.0-sf/3.0)*(1LL<<c.FSC));
          for(int t=0;t<3;t++){
            int64_t N=v[t]-(1<<(bits-1))+d;
            int64_t Nal=N<<(16-bits);            // x*2^15
            int64_t p1=(Nal*Cq)>>(15+c.FC1-22);   // x*C*2^22
            int64_t p2=(p1*sq)>>(22+c.FSC-c.FS); // S*2^FS (floor)
            Sb[ch][t][sb]=sat(p2,c.WS);
          }
        }
        for(int t=0;t<3;t++){
          vpos=(vpos-32)&511;
          for(int ch=0;ch<2;ch++){
            for(int i=0;i<32;i++){ int64_t acc=0;
              for(int j=0;j<32;j++) acc+=Sb[ch][t][j]*cosq((i*(2*j+1))&127);
              V[ch][(vpos+i)&511]=sat(acc>>(c.FS+c.FC-c.FV),c.WV); }
            // resynthesis: win in units 2^-16; acc in 2^-(FV+16)
            int b=vpos+16;
            for(int i=0;i<32;i++){ int64_t acc=0;
              for(int j=0;j<512;j+=64){
                auto Vr=[&](int a){return V[ch][(b+a)&511];};
                auto W=[&](int a){return (int64_t)llround(win[a]*65536);};
                if(i<16) acc+=Vr(i+j)*W(i+j)-Vr(32-i+j)*W(32+i+j);
                else if(i==16) acc-=Vr(16+j)*W(48+j);
                else acc-=Vr(32-i+j)*W(i+j)+Vr(i+j)*W(32+i+j);
              }
              // val = acc*2^15/2^(FV+16) + 0.5, trunc toward zero
              int sh=c.FV+1; int64_t half=1LL<<(sh-1);
              int64_t x=acc+half; int64_t q = x>=0 ? (x>>sh) : -((-x)>>sh);
              if(q>32767)q=32767; if(q<-32768)q=-32768;
              out[(o+i)*2+ch]=(int16_t)q;
            }
          }
          o+=32;
        }
      }
    } catch(Lim){ return false; }
    pos=cur; return true;
  }
};
