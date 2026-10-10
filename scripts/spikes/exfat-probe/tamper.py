import mmap,sys,os
f=open(sys.argv[1],'r+b'); m=mmap.mmap(f.fileno(),0)
marker=("FUJICULL-PROBE-MARKER-%s-"%sys.argv[2]).encode(); ch=sys.argv[3].encode()
n=0; pos=m.find(marker)
while pos!=-1:
    n+=1; m[pos+32:pos+64]=ch*32; pos=m.find(marker,pos+1)
m.flush(); os.fsync(f.fileno()); print("  tampered: %d markers for seed %s -> '%s'"%(n,sys.argv[2],sys.argv[3]))
