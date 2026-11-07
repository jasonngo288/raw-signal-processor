#!/usr/bin/env python3
"""Dump TIFF/DNG IFD tags (pure Python, no deps). Used in CI to explain files CIRAWFilter cannot open."""
import struct, sys, json
NAMES={254:'NewSubFileType',256:'ImageWidth',257:'ImageLength',258:'BitsPerSample',259:'Compression',262:'Photometric',271:'Make',272:'Model',273:'StripOffsets',274:'Orientation',277:'SamplesPerPixel',278:'RowsPerStrip',279:'StripByteCounts',305:'Software',322:'TileWidth',323:'TileLength',324:'TileOffsets',325:'TileByteCounts',330:'SubIFDs',33421:'CFARepeatPatternDim',33422:'CFAPattern',33434:'ExposureTime',34855:'ISO',34665:'ExifIFD',
50706:'DNGVersion',50708:'UniqueCameraModel',50710:'CFAPlaneColor',50711:'CFALayout',50712:'LinearizationTable',50713:'BlackLevelRepeatDim',50714:'BlackLevel',50717:'WhiteLevel',50718:'DefaultScale',50719:'DefaultCropOrigin',50720:'DefaultCropSize',50721:'ColorMatrix1',50722:'ColorMatrix2',50723:'CameraCalibration1',50724:'CameraCalibration2',50727:'AnalogBalance',50728:'AsShotNeutral',50729:'AsShotWhiteXY',50730:'BaselineExposure',50731:'BaselineNoise',50732:'BaselineSharpness',50733:'BayerGreenSplit',50734:'LinearResponseLimit',50778:'CalibrationIlluminant1',50779:'CalibrationIlluminant2',50829:'ActiveArea',50936:'ProfileName',50964:'ForwardMatrix1',50965:'ForwardMatrix2',50981:'ProfileLookTableDims',50982:'ProfileLookTableData',51008:'OpcodeList1',51009:'OpcodeList2',51022:'OpcodeList3',51041:'NoiseProfile',51107:'ProfileToneCurve',51125:'DefaultUserCrop',50740:'DNGPrivateData',51110:'DefaultBlackRender',52525:'ProfileGainTableMap',52529:'?'}
TS={1:1,2:1,3:2,4:4,5:8,6:1,7:1,8:2,9:4,10:8,11:4,12:8,13:4,16:8}
F={1:'B',2:'s',3:'H',4:'I',6:'b',7:'B',8:'h',9:'i',11:'f',12:'d',13:'I',16:'Q'}
d=open(sys.argv[1],'rb').read()
E='<' if d[:2]==b'II' else '>'
def val(t,c,off):
    if t in (5,10):
        f='I' if t==5 else 'i'
        return [struct.unpack_from(E+f,d,off+8*i)[0]/max(1,struct.unpack_from(E+f,d,off+8*i+4)[0]) if struct.unpack_from(E+f,d,off+8*i+4)[0] else 0 for i in range(c)]
    if t==2: return d[off:off+c].rstrip(b'\0').decode('latin1')
    if t==7 and c>64: return f'<{c} bytes @{off}>'
    return list(struct.unpack_from(E+F[t]*c,d,off))
seen=set()
def ifd(off,name,depth=0):
    if off in seen or off==0: return
    seen.add(off)
    n=struct.unpack_from(E+'H',d,off)[0]
    print('  '*depth+f'== {name} @ {off}, {n} tags')
    subs=[]
    for i in range(n):
        tag,t,c,v=struct.unpack_from(E+'HHII',d,off+2+12*i)
        size=TS.get(t,1)*c
        vo=off+2+12*i+8 if size<=4 else v
        try: x=val(t,c,vo)
        except Exception as e: x=f'?{e}'
        nm=NAMES.get(tag,str(tag))
        if isinstance(x,list) and len(x)>24: xs=f'[{len(x)} values] '+str([round(a,4) if isinstance(a,float) else a for a in x[:12]])+'...'
        else: xs=str([round(a,5) if isinstance(a,float) else a for a in x]) if isinstance(x,list) else x
        if tag in (51008,51009,51022): xs=f'<opcode list {c} bytes @ {vo}>'; OP[nm]=(vo,c)
        print('  '*depth+f'  {nm:24s} {xs}')
        if tag in (330,): subs+= x if isinstance(x,list) else [x]
        if tag==34665: subs.append(('Exif',x[0]))
    nxt=struct.unpack_from(E+'I',d,off+2+12*n)[0]
    for s in subs:
        if isinstance(s,tuple): ifd(s[1],s[0],depth+1)
        else: ifd(s,'SubIFD',depth+1)
    if nxt: ifd(nxt,'IFD-next',depth)
OP={}
ifd(struct.unpack_from(E+'I',d,4)[0],'IFD0')
# opcode list decode
for nm,(o,c) in OP.items():
    cnt=struct.unpack_from('>I',d,o)[0]; p=o+4
    print(f'{nm}: {cnt} opcodes')
    for k in range(cnt):
        oid,ver,flags,sz=struct.unpack_from('>IIII',d,p); p+=16
        names={1:'WarpRectilinear',2:'WarpFisheye',3:'FixVignetteRadial',4:'FixBadPixelsConstant',5:'FixBadPixelsList',6:'TrimBounds',7:'MapTable',8:'MapPolynomial',9:'GainMap',10:'DeltaPerRow',11:'DeltaPerColumn',12:'ScalePerRow',13:'ScalePerColumn'}
        extra=''
        if oid==9:
            top,left,bottom,right,plane,planes,rowp,colp,mpv,mph=struct.unpack_from('>10I',d,p)
            spv,sph,ov,oh=struct.unpack_from('>4d',d,p+40); mp=struct.unpack_from('>I',d,p+72)[0]
            extra=f' area=({top},{left},{bottom},{right}) plane={plane}/{planes} pitch=({rowp},{colp}) grid={mpv}x{mph}x{mp}'
            g=struct.unpack_from(f'>{mpv*mph*mp}f',d,p+76)
            extra+=f' gain min={min(g):.3f} max={max(g):.3f}'
        if oid==1:
            nplanes=struct.unpack_from('>I',d,p)[0]; co=struct.unpack_from('>6d',d,p+4); extra=f' planes={nplanes} kr={co} '
        print(f'   {names.get(oid,oid)} flags={flags} size={sz}{extra}')
        p+=sz
