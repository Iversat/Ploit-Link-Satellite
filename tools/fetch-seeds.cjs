const fs=require('node:fs');
const path=require('node:path');
async function main(){
 const catalog=JSON.parse(fs.readFileSync('Resources/catalog.json','utf8')),out=[];
 for(const s of catalog){
  const url=`https://celestrak.org/NORAD/elements/gp.php?CATNR=${s.id}&FORMAT=TLE`;
  try {
   const r=await fetch(url,{signal:AbortSignal.timeout(25000)});if(!r.ok)throw Error(`HTTP ${r.status}`);
   const text=await r.text(),lines=text.split(/\r?\n/).map(x=>x.trim());
   const a=lines.find(x=>x.startsWith('1 ')),b=lines.find(x=>x.startsWith('2 '));
   if(!a||!b||a.length!==69||b.length!==69||+a.slice(2,7)!==s.id)throw Error('No matching TLE');
   out.push({norad:s.id,line1:a,line2:b,fetchedAt:Date.now()/1000-978307200});
   console.log(`${s.name}: ${a.slice(18,32)}`);
  }catch(e){console.log(`${s.name}: ${e.message}`);}
 }
 if(!out.length)throw Error('No seeds; do not invent orbital elements');
 fs.writeFileSync('Resources/seed-tle.json',JSON.stringify(out,null,2)+'\n');
}
main().catch(e=>{console.error(e);process.exit(1)});
