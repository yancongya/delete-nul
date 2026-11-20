/* delete-nul — inject into the offline ASCII Motion mirror (port 4186).
 * Replaces the two hero ASCII wordmark canvases with DELETE / NUL and swaps
 * visible marketing copy. Run via DevTools console or Playwright page.evaluate.
 * Requires: offline mirror running (see REAL-EFFECT.md).
 */
(function(){
  var CHARS=' .:-=+*#%@';
  function drawWord(cv, text){
    if(!cv) return;
    var ctx=cv.getContext('2d'); if(!ctx) return;
    var cols=Math.floor(cv.width/9), rows=Math.floor(cv.height/9);
    if(cols<4||rows<3) return;
    var off=document.createElement('canvas'); off.width=cols; off.height=rows;
    var o=off.getContext('2d'); o.fillStyle='#000'; o.fillRect(0,0,cols,rows);
    o.fillStyle='#fff'; o.textAlign='center'; o.textBaseline='middle';
    var size=Math.min(rows, Math.floor(cols/text.length*1.6));
    o.font='900 '+Math.max(6,size)+'px ui-monospace,monospace';
    o.fillText(text, cols/2, rows/2);
    var d=o.getImageData(0,0,cols,rows).data;
    ctx.clearRect(0,0,cv.width,cv.height);
    ctx.font='9px ui-monospace,monospace'; ctx.textAlign='center'; ctx.textBaseline='middle';
    for(var y=0;y<rows;y++) for(var x=0;x<cols;x++){
      var l=d[(y*cols+x)*4]/255; if(l<0.1) continue;
      ctx.fillStyle='rgba(255,255,255,'+(0.5+l*0.5)+')';
      ctx.fillText(CHARS[Math.min(9,Math.floor(l*9))], x*9+4, y*9+4);
    }
  }
  function loop(){
    var c=document.querySelectorAll('canvas');
    drawWord(c[2],'DELETE');
    drawWord(c[3],'NUL');
    requestAnimationFrame(loop);
  }
  function replaceCopy(){
    var w=document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), n;
    while(n=w.nextNode()){
      n.textContent = n.textContent
        .replace(/ASCII Motion/g,'delete-nul')
        .replace(/An open source tool for creating and animating ASCII art\.[^.]*\.?/gi,
          'A local, open-source tool to delete Windows reserved-name files (NUL, CON, AUX, PRN, COM1-9, LPT1-9).');
    }
    document.title='delete-nul — Windows Reserved-Name File Cleaner';
  }
  replaceCopy();
  setTimeout(replaceCopy, 1500); // catch late-rendered text
  loop();
})();
