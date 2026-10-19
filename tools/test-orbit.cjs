const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const ctx=vm.createContext({console});
vm.runInContext(fs.readFileSync('Resources/satellite.min.js','utf8'),ctx);
vm.runInContext(fs.readFileSync('Resources/orbit.js','utf8'),ctx);
const seeds=JSON.parse(fs.readFileSync('Resources/seed-tle.json','utf8'));
let count=0;
function checksum(line){return line.length===69 && [...line.slice(0,68)].reduce((s,c)=>s+(/\d/.test(c)?+c:c==='-'?1:0),0)%10===+line[68];}
for(const s of seeds){
  assert(checksum(s.line1));assert(checksum(s.line2));assert(ctx.installTLE(s.line1,s.line2));
  const year=+s.line1.slice(18,20),day=+s.line1.slice(20,32);
  const date=Date.UTC(year<57?2000+year:1900+year,0,1)+(day-1)*86400000;
  const look=ctx.lookAt(date,48.708,44.513,100);
  assert(Object.values(look).every(Number.isFinite));assert(look.azimuth>=0&&look.azimuth<360);
  assert(look.elevation>=-90&&look.elevation<=90);assert(look.rangeKm>100);assert(Math.abs(look.rangeRate)<12);
  // Range rate must equal the independently differentiated slant range.
  const r1=ctx.lookAt(date-1000,48.708,44.513,100).rangeKm,r2=ctx.lookAt(date+1000,48.708,44.513,100).rangeKm;
  assert(Math.abs(look.rangeRate-(r2-r1)/2)<0.01);
  const passes=JSON.parse(ctx.passesJSON(date,48.708,44.513,100,10));
  for(const p of passes){
    assert(p.set>p.rise);assert(p.culmination>=p.rise&&p.culmination<=p.set);assert(p.maxElevation>=10&&p.maxElevation<=90);
    if(!p.inProgress) assert(Math.abs(ctx.lookAt(p.rise*1000,48.708,44.513,100).elevation-10)<0.08);
    assert(Math.abs(ctx.lookAt(p.set*1000,48.708,44.513,100).elevation-10)<0.08);
  }
  console.log(`${s.norad}: valid TLE, finite orbit, Doppler derivative, ${passes.length} verified windows`);count++;
}
assert(count>=3);
// Independent published Vallado SGP4 verification vector, t=0, satellite 00005.
const a='1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753';
const b='2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667';
const rec=ctx.satellite.twoline2satrec(a,b), p=ctx.satellite.sgp4(rec,0).position;
assert(Math.abs(p.x-7022.46529266)<0.001);assert(Math.abs(p.y+1400.08296755)<0.001);assert(Math.abs(p.z-0.03995155)<0.001);
console.log('Vallado published verification vector: position error < 1 m; all orbit tests passed.');
