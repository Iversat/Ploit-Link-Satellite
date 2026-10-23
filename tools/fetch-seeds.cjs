const fs=require('node:fs');
function valid(a,b,id,maxAgeDays=3) {
 const checksum=line=>line?.length===69&&[...line.slice(0,68)].reduce((s,c)=>s+(/\d/.test(c)?+c:c==='-'?1:0),0)%10===+line[68];
 if(!a?.startsWith('1 ')||!b?.startsWith('2 ')||+a.slice(2,7)!==id||+b.slice(2,7)!==id||!checksum(a)||!checksum(b))return false;
 const year=+a.slice(18,20),day=+a.slice(20,32);
 const epoch=Date.UTC(year<57?2000+year:1900+year,0,1)+(day-1)*86400000;
 return day>=1&&day<367&&Math.abs(Date.now()-epoch)<=maxAgeDays*86400000;
}
async function main(){
 const catalog=JSON.parse(fs.readFileSync('Resources/catalog.json','utf8')),out=[];
 const previous=JSON.parse(fs.readFileSync('Resources/seed-tle.json','utf8'));let refreshed=0;
 for(const s of catalog){
  const sources=[`https://celestrak.org/NORAD/elements/gp.php?CATNR=${s.id}&FORMAT=TLE`,`https://db.satnogs.org/api/tle/?norad_cat_id=${s.id}`];
  for(const [index,url] of sources.entries()) {
   try {
    const r=await fetch(url,{signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error(`HTTP ${r.status}`);
    let candidates;
    if(index===0) {
     const lines=(await r.text()).split(/\r?\n/).map(x=>x.trim());
     candidates=[[lines.find(x=>x.startsWith('1 ')),lines.find(x=>x.startsWith('2 '))]];
    }else {
     candidates=(await r.json()).filter(x=>x.norad_cat_id===s.id).map(x=>[x.tle1,x.tle2]);
    }
    const match=candidates.filter(([a,b])=>valid(a,b,s.id)).sort((a,b)=>b[0].slice(18,32).localeCompare(a[0].slice(18,32)))[0];
    if(!match)throw Error('No matching checksum-valid TLE newer than 3 days');
    const [a,b]=match;
    out.push({norad:s.id,line1:a,line2:b,fetchedAt:Date.now()/1000-978307200});
    refreshed++;
    console.log(`${s.name}: ${a.slice(18,32)} from ${new URL(url).hostname}`);break;
   }catch(e){console.log(`${s.name} (${new URL(url).hostname}): ${e.message}`);}
  }
  if(!out.some(x=>x.norad===s.id)) {
   const old=previous.find(x=>x.norad===s.id&&valid(x.line1,x.line2,s.id,Infinity));
   if(old){out.push(old);console.log(`${s.name}: retained old epoch ${old.line1.slice(18,32)}; fresh data unavailable`);}
  }
 }
 if(!refreshed||out.length!==catalog.length)throw Error('No complete validated catalogue; existing seeds preserved');
 fs.writeFileSync('Resources/seed-tle.json',JSON.stringify(out,null,2)+'\n');
}
main().catch(e=>{console.error(e);process.exit(1)});
