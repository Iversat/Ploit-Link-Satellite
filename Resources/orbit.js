/* Local SGP4 bridge. satellite.js 6.0.1, MIT. No network or user-location logging. */
var currentSatrec = null;
function installTLE(a,b) {
  currentSatrec = satellite.twoline2satrec(a,b);
  return !!currentSatrec && currentSatrec.error === 0;
}
function lookAt(ms, lat, lon, altM) {
  var date = new Date(ms), gmst = satellite.gstime(date);
  var pv = satellite.propagate(currentSatrec,date);
  if (!pv || !pv.position || !pv.velocity || currentSatrec.error) throw new Error('SGP4 unavailable');
  var observer = {latitude:lat*Math.PI/180,longitude:lon*Math.PI/180,height:altM/1000};
  var ecf = satellite.eciToEcf(pv.position,gmst);
  var angles = satellite.ecfToLookAngles(observer,ecf);
  var geo = satellite.eciToGeodetic(pv.position,gmst);
  var o = satellite.geodeticToEcf(observer);
  // Central finite difference includes rotating terrestrial observer, in km/s.
  function range(t) {
    var d=new Date(t), p=satellite.propagate(currentSatrec,d).position;
    if(!p) throw new Error('Decayed orbit');
    var q=satellite.eciToEcf(p,satellite.gstime(d));
    return Math.hypot(q.x-o.x,q.y-o.y,q.z-o.z);
  }
  return {azimuth:angles.azimuth*180/Math.PI,elevation:angles.elevation*180/Math.PI,
    rangeKm:angles.rangeSat,rangeRate:(range(ms+500)-range(ms-500)),
    latitude:geo.latitude*180/Math.PI,longitude:geo.longitude*180/Math.PI,altitudeKm:geo.height};
}
function lookJSON(ms,lat,lon,alt) { return JSON.stringify(lookAt(ms,lat,lon,alt)); }
function stateAt(ms) {
  var date=new Date(ms), gmst=satellite.gstime(date),pv=satellite.propagate(currentSatrec,date);
  if(!pv || !pv.position || currentSatrec.error) throw new Error('SGP4 unavailable');
  var geo=satellite.eciToGeodetic(pv.position,gmst);
  return {position:satellite.eciToEcf(pv.position,gmst),latitude:geo.latitude*180/Math.PI,
    longitude:geo.longitude*180/Math.PI,altitudeKm:geo.height,periodSeconds:2*Math.PI/currentSatrec.no*60};
}
function stateJSON(ms) {return JSON.stringify(stateAt(ms));}
function motionJSON(ms,seconds,step) {
  var samples=[];
  for(var i=0;i<=Math.ceil(seconds/step);i++) samples.push(stateAt(ms+i*step*1000));
  return JSON.stringify(samples);
}
function trajectoryJSON(ms) {
  var state=stateAt(ms),period=state.periodSeconds*1000,gmst=satellite.gstime(new Date(ms)),orbit=[],ground=[];
  for(var i=0;i<=120;i++) {
    var t=ms+(i/120-0.5)*period,date=new Date(t),pv=satellite.propagate(currentSatrec,date);
    if(!pv || !pv.position || currentSatrec.error) throw new Error('SGP4 unavailable');
    // Instantaneous orbit in the Earth's frame at the displayed time.
    orbit.push(satellite.eciToEcf(pv.position,gmst));
    // Ground track uses Earth's actual rotation at each sample time.
    var geo=satellite.eciToGeodetic(pv.position,satellite.gstime(date));
    ground.push(satellite.geodeticToEcf({latitude:geo.latitude,longitude:geo.longitude,height:12}));
  }
  return JSON.stringify({orbit:orbit,ground:ground});
}
function passesJSON(ms,lat,lon,alt,mask) {
  // 48 h, 15 s coarse scan + 0.25 s crossing bisection; a mask-defined RF window.
  var end=ms+48*3600000, step=15000, result=[], active=null;
  function el(t){
    var d=new Date(t),pv=satellite.propagate(currentSatrec,d);
    if(!pv || !pv.position || currentSatrec.error) throw new Error('SGP4 unavailable');
    return satellite.ecfToLookAngles({latitude:lat*Math.PI/180,longitude:lon*Math.PI/180,height:alt/1000},
      satellite.eciToEcf(pv.position,satellite.gstime(d))).elevation*180/Math.PI;
  }
  function cross(a,b,rising){for(var k=0;k<16 && b-a>250;k++){var m=(a+b)/2;if((el(m)>=mask)===rising)b=m;else a=m;}return(a+b)/2;}
  var prev=el(ms);
  if(prev>=mask) {
    // Recover AOS and an earlier culmination when opening during a LEO pass.
    var rise=ms;
    for(var back=ms-step;back>=ms-3*3600000;back-=step) {
      if(el(back)<mask) {rise=cross(back,back+step,true);break;}
    }
    active={rise:rise/1000,culmination:ms/1000,maxElevation:prev,inProgress:true};
    for(var past=rise;past<ms;past+=step) {
      var pastEl=el(past);
      if(pastEl>active.maxElevation){active.maxElevation=pastEl;active.culmination=past/1000;}
    }
  }
  for(var t=ms+step;t<=end;t+=step){
    var elevation=el(t);
    if(!active&&prev<mask&&elevation>=mask){active={rise:cross(t-step,t,true)/1000,culmination:t/1000,maxElevation:elevation,inProgress:false};}
    if(active){
      if(elevation>active.maxElevation){active.maxElevation=elevation;active.culmination=t/1000;}
      if(elevation<mask){active.set=cross(t-step,t,false)/1000;result.push(active);active=null;if(result.length>=64)break;}
    }
    prev=elevation;
  }
  // An unfinished window is not presented as a completed pass.
  return JSON.stringify(result);
}
if(typeof module!=='undefined') module.exports={installTLE,lookAt,lookJSON,passesJSON,stateAt,stateJSON,motionJSON,trajectoryJSON};
