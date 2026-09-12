hostname=mp.weixin.qq.com
# 番茄看看前台阅读
^http://.+/yunonline/v1/task url script-response-body https://raw.githubusercontent.com/LucaLin233/ScriptCopy_feizao/main/fqkk_auto_read.js
^http://.+/(reada/jump|v1/jump|task/read)\? url script-response-header https://raw.githubusercontent.com/LucaLin233/ScriptCopy_feizao/main/fqkk_auto_read.js
^http://.+/mock/read url script-analyze-echo-response https://raw.githubusercontent.com/LucaLin233/ScriptCopy_feizao/main/fqkk_auto_read.js
^https?://mp\.weixin\.qq\.com/s.+?k=feizao url response-body </script> response-body setTimeout(()=>window.history.back(),10000); </script>
