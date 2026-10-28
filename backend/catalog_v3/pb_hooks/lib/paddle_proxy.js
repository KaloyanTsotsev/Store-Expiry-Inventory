'use strict';
function failure(e,status,code){return e.json(status,{code:code});}
function decode(value){
  if(typeof value!=='string'||!value.length||value.length%4||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value))throw new Error('invalid_base64');
  const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const bytes=[];
  for(let i=0;i<value.length;i+=4){
    const a=alphabet.indexOf(value[i]),b=alphabet.indexOf(value[i+1]);
    const c=alphabet.indexOf(value[i+2]),d=alphabet.indexOf(value[i+3]);
    bytes.push((a<<2)|(b>>4));
    if(c>=0)bytes.push(((b&15)<<4)|(c>>2));
    if(d>=0)bytes.push(((c&3)<<6)|d);
  }
  return bytes;
}
function recognize(e){
  if($os.getenv('STORE_OCR_PROVIDER')!=='paddle-v5'||$os.getenv('STORE_OCR_URL')!=='http://127.0.0.1:8765/ocr')return failure(e,503,'paddle_not_configured');
  const actor=e.app.findRecordById('employees',e.auth.id);
  if(!['employee','manager','admin'].includes(actor.getString('role')))return failure(e,403,'ocr_forbidden');
  const input=e.requestInfo().body;
  if(Object.keys(input).some(k=>k!=='image_base64'))return failure(e,400,'invalid_ocr_request');
  if(typeof input.image_base64==='string'&&input.image_base64.length>12582912)return failure(e,413,'image_too_large');
  const token=$security.randomString(32),key='store.paddle.ocr.slot';
  // Store.SetFunc holds the Go store mutex: atomic across isolated JSVMs.
  e.app.store().setFunc(key,old=>old||token);
  if(e.app.store().get(key)!==token)return failure(e,429,'ocr_busy');
  try{
    let bytes;
    try{bytes=decode(input.image_base64);}catch(_){return failure(e,400,'invalid_image');}
    if(bytes.length>9437184)return failure(e,413,'image_too_large');
    const png=[137,80,78,71,13,10,26,10].every((b,i)=>bytes[i]===b);
    const jpeg=bytes[0]===255&&bytes[1]===216&&bytes[2]===255;
    if(!png&&!jpeg)return failure(e,415,'unsupported_image');
    const form=new FormData();
    form.append('image',$filesystem.fileFromBytes(bytes,png?'document.png':'document.jpg'));
    let response;
    try{response=$http.send({url:'http://127.0.0.1:8765/ocr',method:'POST',body:form,timeout:195});}
    catch(_){return failure(e,503,'ocr_unavailable_or_proxy_timeout');}
    if(response.statusCode!==200){
      const status=[400,413,429,504].includes(response.statusCode)?response.statusCode:503;
      return failure(e,status,'ocr_upstream_'+status);
    }
    const result=response.json;
    if(response.body.length>1048576||!result||result.status!=='ok'||result.engine!=='PaddleOCR PP-OCRv5'||!Array.isArray(result.products)||result.products.length>500)return failure(e,502,'invalid_paddle_response');
    return e.json(200,result);
  }finally{
    e.app.store().setFunc(key,old=>old===token?null:old);
  }
}
module.exports={recognize,decode};
