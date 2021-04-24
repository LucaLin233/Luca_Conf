hostname=mp.weixin.qq.com
# 番茄看看前台阅读
^http://.+/(task/read|jump)\? url script-response-header https://raw.githubusercontent.com/LucaLin233/ScriptCopy_feizao/main/fqkk_auto_read.js
^https?://mp\.weixin\.qq\.com/s.+?k=feizao url response-body var ua = navigator.userAgent; response-body var ua = navigator.userAgent; setTimeout(()=>window.history.back(),9000);
