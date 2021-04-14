# QuantumultX自用脚本配置及简易食用教程
### 初版，如有发现编写错误和个人建议欢迎提issue
### 本仓库之中所有脚本配置纯属自用备份
### 请不要fork，自行同步
# 免责声明
- LucaLin233 发布的本仓库中涉及的任何解锁和解密分析脚本仅用于资源共享和学习研究，不能保证其合法性，准确性，完整性和有效性，请根据情况自行判断.

- 间接使用脚本的任何用户，包括但不限于建立VPS或在某些行为违反国家/地区法律或相关法规的情况下进行传播, LucaLin233 对于由此引起的任何隐私泄漏或其他后果概不负责.

- 请勿将本仓库内的任何内容用于商业或非法目的，否则后果自负.

- 如果任何单位或个人认为该项目的脚本可能涉嫌侵犯其权利，则应及时通知并提供身份证明，所有权证明，我将在收到认证文件后删除相关脚本.

- LucaLin233 对任何本仓库中包含的脚本在使用中可能出现的问题概不负责，包括但不限于由任何脚本错误导致的任何损失或损害.

- 您必须在下载后的24小时内从计算机或手机中完全删除以上内容.

- 任何以任何方式查看此项目的人或直接或间接使用该项目的任何脚本的使用者都应仔细阅读此声明。LucaLin233 保留随时更改或补充此免责声明的权利。一旦使用并复制了任何本仓库相关脚本或其他内容，则视为您已接受此免责声明.

## 补充说明
- 本仓库只搬运各位大佬的脚本作为自用库使用，并不负责维护脚本.
- 不保证所有脚本的可用性.
- 因你个人食用姿势不正确所导致的脚本不可用的问题，禁止issue，也一概不予解决.
- 本仓库不提供QuantumultX的配置文件，如有需要请往下看.

### 食用本仓库脚本的前提条件——学会QuantumultX
- 浏览[Quantumult X教程](https://www.notion.so/Quantumult-X-1d32ddc6e61c4892ad2ec5ea47f00917)了解配置文件使用方法（懒人请直接阅读第五大点学习配置导入）

- 参考或直接使用下方[@KOP-XIAO](https://github.com/KOP-XIAO)大佬的懒人配置
  - [Quantumult X懒人配置](https://raw.githubusercontent.com/KOP-XIAO/QuantumultX/master/QuantumultX_Profiles.conf)

- 下面是由[@limbopro](https://github.com/limbopro)写的常用正则表达筛选公式,或许对你筛选节点有帮助:
  - **https://limbopro.xyz/archives/11131.html**

- 另附分流规则推荐：[@blackmatrix7分流规则](https://github.com/blackmatrix7/ios_rule_script)

- 吃透以上几点，对于QuantumultX的初步玩法想必你已经掌握得差不多了，请往下看。

### 脚本食用（长按复制链接食用即可）
- [Get Cookies远程重写](https://raw.githubusercontent.com/LucaLin233/Luca_Conf/main/Profile/Luca_Get_Cookies.conf)
  - 如果你使用的是ztxtop的看看赚，请添加他的看看赚CK重写：[中青看看赚](https://raw.githubusercontent.com/ztxtop/x/main/rewrite-zqkkz.plugin)
  - 补充中青抓body重写：[中青抓body](https://raw.githubusercontent.com/LucaLin233/ScriptCopy_Maomaoyu0319/main/TaskConf/youth/qx_youthread.txt)

  **食用方式如下（在下图中的框框内填入重写链接）**
  
  ![](https://github.com/LucaLin233/Luca_Conf/blob/main/Icon/%E9%87%8D%E5%86%99%E9%A3%9F%E7%94%A81.png)
- [Gallery仓库](https://raw.githubusercontent.com/LucaLin233/Luca_Conf/main/Profile/Luca_Gallery.json)
  
  **食用方式如下（在下图标记的+号中填入链接仓库链接）**
  
  ![](https://github.com/LucaLin233/Luca_Conf/blob/main/Icon/%E8%84%9A%E6%9C%AC%E9%A3%9F%E7%94%A81.jpg)
- 已引用的大佬脚本如下：
  - By[@whyour](https://github.com/whyour)
    - 京喜财富岛提现
  - By[@lxk0301](https://github.com/lxk0301)
    - CrazyJoy挂机
  - By[@Sunert](https://github.com/Sunert)
    - 中青系列
  - By[@age174](https://github.com/age174)
    - 云扫码
    - 番茄看看
    - 西梅
    - 葫芦音乐
    - V生活
    - 千禾阅读（需自行添加本地CK重写）
  - By[@yangtingxiao](https://github.com/yangtingxiao)
    - 抽奖机（京东）
    - 排行榜（京东）
  - By[@NobyDa](https://github.com/NobyDa)
    - 京东多合一签到
  - By[@blackmatrix7](https://github.com/blackmatrix7)
    - 滴滴出行系列
- 本仓库脚本建议配合LXK的京东系列脚本食用，以达到良好的薅羊毛体验（bushi）
- LXK大佬最新Gallery地址：[LXK0301](https://jdsharedresourcescdn.azureedge.net/jdresource/lxk0301_gallery.json)
  - 请添加对应域名规则并指向proxy，或使用全局代理的方式食用lxk大佬的Gallery。（PS：不要使用香港节点）
### 一些APP JS重写规则（如同上方的Get Cookies重写使用方式一致，长按复制链接食用即可）
- [JS重写规则](https://raw.githubusercontent.com/LucaLin233/Luca_Conf/main/Profile/Luca_Apps_JS.conf)
- 具体内容自己体验或查看库内代码说明，懂的都懂
### 新增Emby分流规则
- 包含以下服务器：
  - 普拉斯AGA服务器（中国电信直连使用）
  - CF公益服(仅限挂代理观看)
  - 普拉斯备用服（4个）
  - Exflux专属服
  - Nexitally/AmyTelecom专属服(共用，仅限美国特定节点观看，佩奇已标注）

### 特别感谢以下脚本作者以及整合时参考的作者 
- [@NobyDa](https://github.com/NobyDa)
- [@chavyleung](https://github.com/chavyleung)
- [@Sunert](https://github.com/Sunert)
- [@lxk0301](https://github.com/lxk0301)
- [@blackmatrix7](https://github.com/blackmatrix7)
- [@WowYiJiu](https://github.com/WowYiJiu)
- [@ZhiYi-N](https://github.com/ZhiYi-N)
- @ziye（防止大佬再被封，故不贴出）
- [@age174](https://github.com/age174)
- [@yangtingxiao](https://github.com/yangtingxiao)
- [@ChuheGit](https://github.com/ChuheGit)
- [@zZPiglet](https://github.com/zZPiglet)
- [@whyour](https://github.com/whyour)
### 配置文件作者
- [@KOP-XIAO](https://github.com/KOP-XIAO)
### 分流规则作者
- [@blackmatrix7](https://github.com/blackmatrix7)
### 图标作者
- [@shoujiqiyuan](https://github.com/shoujiqiyuan)
- [@erdongchanyo](https://github.com/erdongchanyo)
- [@Orz-3](https://github.com/Orz-3)
- [@ChuheGit](https://github.com/ChuheGit)
- [@58xinian](https://github.com/58xinian)
- @ziye（防止大佬再被封，故不贴出）
### (排名不分先后，如有遗漏万分抱歉，请联系我加上）

### 如果我编写的简易说明和整合的脚本对你的QuantumultX使用有帮助，可否麻烦你点个*Star*, 感激不尽:gift_heart::gift_heart::gift_heart:.
