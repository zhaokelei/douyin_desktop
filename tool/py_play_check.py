# -*- coding: utf-8 -*-
"""对照探针：用参考实现的同一套流程取播放地址并直接请求，只看状态码。
不写任何 cookie 到磁盘，不修改参考仓库内文件。"""
import os
import sys

REF = r"C:\Users\Administrator\Documents\Trae-CN\temp_20261107_03\ref_douyin_spider"
sys.path.insert(0, REF)
os.chdir(REF)

import dy_apis.douyin_api as _dyapi  # noqa: F401  先导入，避免循环引用
from dy_apis.login_api import DYLoginApi
from dy_apis.douyin_api import DouyinAPI
from builder.header import HeaderBuilder, HeaderType
from builder.params import Params
from utils import http_client as requests

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36")


def main():
    auth = DYLoginApi.bootstrap_auth("", strict=False)
    print("bootstrap 完成，cookie 字段数 =", len(auth.cookie))

    headers = HeaderBuilder().build(HeaderType.GET)
    headers.set_referer("https://www.douyin.com/")
    params = Params()
    params.with_platform()
    params.add_param("count", "10")
    params.add_param("refresh_index", "1")
    params.add_param("is_non_personalized", "0")
    params.with_web_id(auth, "https://www.douyin.com/")
    params.add_param("msToken", auth.msToken)
    params.with_a_bogus()
    resp = requests.get("https://www.douyin.com/aweme/v1/web/tab/feed/",
                        headers=headers.get(), params=params.get(),
                        cookies=auth.cookie, verify=False, timeout=30)
    print("[feed] HTTP", resp.status_code)
    j = resp.json() if resp.text else {}
    lst = j.get("aweme_list") or []
    print("[feed] aweme_list =", len(lst), "status_code =", j.get("status_code"))
    if not lst:
        return
    aid = lst[0].get("aweme_id")
    print("[feed] 选中 aweme:", aid)

    detail = DouyinAPI.get_work_info(auth, f"https://www.douyin.com/video/{aid}")
    item = detail.get("aweme_detail") or {}
    play = ((item.get("video") or {}).get("play_addr") or {}).get("url_list") or []
    print("[detail] 播放地址数 =", len(play))
    if play:
        url = play[0]
        print("[play] 地址长度 =", len(url))
        for tag, hdrs in (
            ("UA+Referer", {"User-Agent": UA, "Referer": "https://www.douyin.com/"}),
            ("UA+Referer+Cookie", {"User-Agent": UA,
                                   "Referer": "https://www.douyin.com/"}),
        ):
            try:
                r = requests.get(url, headers=hdrs, verify=False, timeout=30,
                                 stream=True,
                                 cookies=auth.cookie if "Cookie" in tag else None)
                print("[play] %s -> HTTP %s len=%s ct=%s" % (
                    tag, r.status_code, len(r.content), r.headers.get("content-type")))
            except Exception as e:
                print("[play] %s -> 异常 %s: %s" % (tag, type(e).__name__, e))

    cm = DouyinAPI.get_work_out_comment(
        auth, f"https://www.douyin.com/video/{aid}", "0")
    cs = cm.get("comments") or []
    print("[comment] comments =", len(cs), "has_more =", cm.get("has_more"),
          "| 顶层字段 =", list(cm.keys())[:8])


if __name__ == "__main__":
    main()
