#!/usr/bin/env python3
"""Export formal HUD sprite/font resources and the current Source header recipe."""
import argparse, gzip, hashlib, json
from pathlib import Path

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--release-root',type=Path,required=True);ap.add_argument('--output',type=Path,required=True);args=ap.parse_args();root=args.release_root;proof=[]
    def source(path):
        meta=root/'metadata/sources'/f'{path}.json';m=json.loads(meta.read_bytes());a=m['objectArchive'];data=root/a['path']
        if digest(data)!=a['sha256']or a['failedObjectCount']:raise ValueError(path)
        rows=[json.loads(x)for x in gzip.decompress(data.read_bytes()).splitlines()];proof.append({'source':path,'metadataSha256':digest(meta),'archiveSha256':a['sha256']});return m,[r for r in rows if r.get('record')=='object']
    live='Assets/AddressableResources/Live/Images/Atlas/LiveAtlas.spriteatlasv2';meta,rows=source(live);sprites={}
    wanted={'rankBase':'SP_ingame_header_rankbase','round':'CircleBase14px_Mask_ingame','status':'circle_ingame_half','star':'star_ingame','lifeNormal':'SP_ingame_icon_life','lifeDanger':'SP_ingame_icon_life_danger_0','lifeOver':'SP_ingame_icon_life_over_0','pauseFrame':'FrameNormalButton_H80_ingame','pauseShadow':'FrameNormalButton_H80_Shadow_ingame','pauseIcon':'IconPause_ingame'}
    def sprite(key,name,m,objects,asset_path=None):
        row=next(r for r in objects if r['type']=='Sprite'and r['data'].get('m_Name')==name);d=row['data'];rd=d['m_RD'];pid=str(row['pathId']);out=next(o for o in m['outputs']if o['type']=='Sprite'and str(o['objectId'])==pid and o['serializedFile']==row['serializedFile']);p=root/out['path'];assert digest(p)==out['sha256'];rect=d['m_Rect'];tr=rd['textureRect'];off=rd['textureRectOffset'];b=d['m_Border'];sprites[key]={'path':asset_path or out['path'],'sha256':out['sha256'],'rect':[rect['width'],rect['height']],'trim':[tr['width'],tr['height']],'offset':[off['x'],off['y']],'border':[b['x'],b['y'],b['z'],b['w']],'sourceId':pid,'serializedFile':row['serializedFile']}
    for k,n in wanted.items():sprite(k,n,meta,rows)
    for rank in ['D','C','B','A','S','SS']:
        path=f'Assets/AddressableResources/Effect/Live/RankIcon/Texture/RankIconAtlas/scorerank_{rank.lower()}_ingame.png';m,r=source(path);sprite('rank'+rank,'scorerank_'+rank.lower()+'_ingame',m,r,'assets/'+path)
    m,r=source('Assets/AddressableResources/UI/Atlas/FixUiSpriteAtlas.spriteatlasv2');sprite('white','WhiteRect',m,r)
    font_path='Packages/com.fromtokyo.sirius-asset/AddressableResources/Font/VibeMOPro-Medium/VibeMOPro-Medium SDF.asset';m,r=source(font_path);f=next(x['data']for x in r if x['type']=='MonoBehaviour'and 'm_FaceInfo'in x['data']);face=f['m_FaceInfo'];atlas=next(o for o in m['outputs']if o['type']=='Texture2D');assert digest(root/atlas['path'])==atlas['sha256']
    font={'path':atlas['path'],'sha256':atlas['sha256'],'size':face['m_PointSize'],'scale':face['m_Scale'],'ascent':face['m_AscentLine'],'descent':face['m_DescentLine'],'padding':f['m_AtlasPadding'],'width':f['m_AtlasWidth'],'height':f['m_AtlasHeight'],'characters':{str(c['m_Unicode']):[c['m_GlyphIndex'],c['m_Scale']]for c in f['m_CharacterTable']},'glyphs':{str(g['m_Index']):{'rect':[g['m_GlyphRect'][k]for k in['m_X','m_Y','m_Width','m_Height']],'metrics':[g['m_Metrics'][k]for k in['m_Width','m_Height','m_HorizontalBearingX','m_HorizontalBearingY','m_HorizontalAdvance']],'scale':g['m_Scale']}for g in f['m_GlyphTable']},'pairs':f.get('m_FontFeatureTable',{}).get('m_GlyphPairAdjustmentRecords',[])}
    required=set(map(ord,'0123456789+-RANKLIVESCOREDCBASS '));font['characters']={k:v for k,v in font['characters'].items()if int(k)in required};glyphs={v[0]for v in font['characters'].values()};font['glyphs']={k:v for k,v in font['glyphs'].items()if int(k)in glyphs}
    pairs=[]
    for pair in font['pairs']:
        a=pair['m_FirstAdjustmentRecord'];b=pair['m_SecondAdjustmentRecord']
        if a['m_GlyphIndex']not in glyphs or b['m_GlyphIndex']not in glyphs:continue
        def value(record):return [record['m_GlyphValueRecord'][k]for k in ['m_XPlacement','m_YPlacement','m_XAdvance']]
        pairs.append([a['m_GlyphIndex'],b['m_GlyphIndex'],value(a),value(b)])
    font['pairs']=pairs
    packet={'schema':'our-notes-header-v1','sprites':sprites,'font':font,'rankFallback':[553524,2136175,4548528,9150398,12945117],'rankPositions':[88,177,264,352,439],'rankLabels':['D','C','B','A','S','SS'],'rankGaugeWidth':502,'maxScoreRate':1.2000000476837158,'scoreDeltaSeconds':.45,'pause':{'frame':[100,19,80,80],'shadow':[100,22.36,80,90.54],'icon':[92,27,64,64]},'sourceProof':proof}
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(packet,separators=(',',':'),ensure_ascii=False)+'\n');print(len(sprites),'sprites',len(font['characters']),'characters',len(font['pairs']),'kerning pairs',digest(args.output))
if __name__=='__main__':main()
