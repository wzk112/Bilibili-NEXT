import SwiftUI

struct VideoRegion: Identifiable, Hashable {
  let id: Int
  let title: String
  var children: [VideoRegion] = []
  // Public channel metadata from bilibili.com/c/douga/, checked 2026-10-21.
  static let all: [VideoRegion] = [
    .init(id: 1005, title: "动画", children: [.init(id: 2037, title: "同人动画"), .init(id: 2038, title: "模玩周边"), .init(id: 2039, title: "cosplay"), .init(id: 2040, title: "二次元线下"), .init(id: 2041, title: "动漫剪辑"), .init(id: 2042, title: "动漫评论"), .init(id: 2043, title: "动漫速读"), .init(id: 2044, title: "动漫配音"), .init(id: 2045, title: "动漫资讯"), .init(id: 2046, title: "网文解读"), .init(id: 2047, title: "虚拟up主"), .init(id: 2048, title: "特摄"), .init(id: 2049, title: "布袋戏"), .init(id: 2050, title: "漫画·动态漫"), .init(id: 2051, title: "广播剧"), .init(id: 2052, title: "动漫reaction"), .init(id: 2053, title: "动漫教学"), .init(id: 2054, title: "二次元其他")]),
    .init(id: 1008, title: "游戏", children: [.init(id: 2064, title: "单人RPG游戏"), .init(id: 2065, title: "MMORPG游戏"), .init(id: 2066, title: "单机主机类游戏"), .init(id: 2067, title: "SLG游戏"), .init(id: 2068, title: "回合制策略游戏"), .init(id: 2069, title: "即时策略游戏"), .init(id: 2070, title: "MOBA游戏"), .init(id: 2071, title: "射击游戏"), .init(id: 2072, title: "体育竞速游戏"), .init(id: 2073, title: "动作竞技游戏"), .init(id: 2074, title: "音游舞游"), .init(id: 2075, title: "模拟经营游戏"), .init(id: 2076, title: "女性向游戏"), .init(id: 2077, title: "休闲/小游戏"), .init(id: 2078, title: "沙盒类"), .init(id: 2079, title: "其他游戏")]),
    .init(id: 1007, title: "鬼畜", children: [.init(id: 2059, title: "鬼畜调教"), .init(id: 2060, title: "鬼畜剧场"), .init(id: 2061, title: "人力VOCALOID"), .init(id: 2062, title: "音MAD"), .init(id: 2063, title: "鬼畜综合")]),
    .init(id: 1003, title: "音乐", children: [.init(id: 2016, title: "原创音乐"), .init(id: 2017, title: "MV"), .init(id: 2018, title: "音乐现场"), .init(id: 2019, title: "乐迷饭拍"), .init(id: 2020, title: "翻唱"), .init(id: 2021, title: "演奏"), .init(id: 2022, title: "VOCALOID"), .init(id: 2023, title: "AI音乐"), .init(id: 2024, title: "电台·歌单"), .init(id: 2025, title: "音乐教学"), .init(id: 2026, title: "乐评盘点"), .init(id: 2027, title: "音乐综合")]),
    .init(id: 1004, title: "舞蹈", children: [.init(id: 2028, title: "宅舞"), .init(id: 2029, title: "街舞"), .init(id: 2030, title: "颜值·网红舞"), .init(id: 2031, title: "明星舞蹈"), .init(id: 2032, title: "国风舞蹈"), .init(id: 2033, title: "舞蹈教学"), .init(id: 2034, title: "芭蕾舞"), .init(id: 2035, title: "wota艺"), .init(id: 2036, title: "舞蹈综合")]),
    .init(id: 1001, title: "影视", children: [.init(id: 2001, title: "影视解读"), .init(id: 2002, title: "影视剪辑"), .init(id: 2003, title: "影视资讯"), .init(id: 2004, title: "影视正片搬运"), .init(id: 2005, title: "短剧短片"), .init(id: 2006, title: "AI影视"), .init(id: 2007, title: "影视reaction"), .init(id: 2008, title: "影视综合")]),
    .init(id: 1002, title: "娱乐", children: [.init(id: 2009, title: "娱乐评论"), .init(id: 2010, title: "明星剪辑"), .init(id: 2011, title: "娱乐饭拍&现场"), .init(id: 2012, title: "娱乐资讯"), .init(id: 2013, title: "娱乐reaction"), .init(id: 2014, title: "娱乐综艺正片"), .init(id: 2015, title: "娱乐综合")]),
    .init(id: 1010, title: "知识", children: [.init(id: 2084, title: "应试教育"), .init(id: 2085, title: "非应试语言学习"), .init(id: 2086, title: "大学专业知识"), .init(id: 2087, title: "商业财经"), .init(id: 2088, title: "社会观察"), .init(id: 2089, title: "时政解读"), .init(id: 2090, title: "人文历史"), .init(id: 2091, title: "设计艺术"), .init(id: 2092, title: "心理杂谈"), .init(id: 2093, title: "职场发展"), .init(id: 2094, title: "科学科普"), .init(id: 2095, title: "其他知识杂谈")]),
    .init(id: 1012, title: "科技数码", children: [.init(id: 2099, title: "电脑"), .init(id: 2100, title: "手机"), .init(id: 2101, title: "平板电脑"), .init(id: 2102, title: "摄影摄像"), .init(id: 2103, title: "工程机械"), .init(id: 2104, title: "自制发明/设备"), .init(id: 2105, title: "科技数码综合")]),
    .init(id: 1009, title: "资讯", children: [.init(id: 2080, title: "时政资讯"), .init(id: 2081, title: "海外资讯"), .init(id: 2082, title: "社会资讯"), .init(id: 2083, title: "综合资讯")]),
    .init(id: 1020, title: "美食", children: [.init(id: 2149, title: "美食制作"), .init(id: 2150, title: "美食探店"), .init(id: 2151, title: "美食测评"), .init(id: 2152, title: "美食记录"), .init(id: 2153, title: "美食综合")]),
    .init(id: 1021, title: "小剧场", children: [.init(id: 2154, title: "剧情演绎"), .init(id: 2155, title: "语言类小剧场"), .init(id: 2156, title: "UP主小综艺"), .init(id: 2157, title: "街头采访")]),
    .init(id: 1013, title: "汽车", children: [.init(id: 2106, title: "汽车测评"), .init(id: 2107, title: "汽车文化"), .init(id: 2108, title: "汽车生活"), .init(id: 2109, title: "汽车技术"), .init(id: 2110, title: "汽车综合")]),
    .init(id: 1014, title: "时尚美妆", children: [.init(id: 2111, title: "美妆"), .init(id: 2112, title: "护肤"), .init(id: 2113, title: "仿装cos"), .init(id: 2114, title: "鞋服穿搭"), .init(id: 2115, title: "箱包配饰"), .init(id: 2116, title: "珠宝首饰"), .init(id: 2117, title: "三坑"), .init(id: 2118, title: "时尚解读"), .init(id: 2119, title: "时尚综合")]),
    .init(id: 1018, title: "体育运动", children: [.init(id: 2133, title: "潮流运动"), .init(id: 2134, title: "足球"), .init(id: 2135, title: "篮球"), .init(id: 2136, title: "跑步"), .init(id: 2137, title: "武术"), .init(id: 2138, title: "格斗"), .init(id: 2139, title: "羽毛球"), .init(id: 2140, title: "体育资讯"), .init(id: 2141, title: "体育赛事"), .init(id: 2142, title: "体育综合")]),
    .init(id: 1011, title: "人工智能", children: [.init(id: 2096, title: "AI学习"), .init(id: 2097, title: "AI资讯"), .init(id: 2098, title: "AI杂谈")]),
    .init(id: 1006, title: "绘画", children: [.init(id: 2055, title: "二次元绘画"), .init(id: 2056, title: "非二次元绘画"), .init(id: 2057, title: "绘画学习"), .init(id: 2058, title: "绘画综合")]),
    .init(id: 1015, title: "家装房产", children: [.init(id: 2120, title: "买房租房"), .init(id: 2121, title: "家庭装修"), .init(id: 2122, title: "家居展示"), .init(id: 2123, title: "家用电器")]),
    .init(id: 1016, title: "户外潮流", children: [.init(id: 2124, title: "露营"), .init(id: 2125, title: "徒步"), .init(id: 2126, title: "户外探秘"), .init(id: 2127, title: "户外综合")]),
    .init(id: 1017, title: "健身", children: [.init(id: 2128, title: "健身科普"), .init(id: 2129, title: "健身跟练教学"), .init(id: 2130, title: "健身记录"), .init(id: 2131, title: "健身身材展示"), .init(id: 2132, title: "健身综合")]),
    .init(id: 1019, title: "手工", children: [.init(id: 2143, title: "文具手帐"), .init(id: 2144, title: "轻手作"), .init(id: 2145, title: "传统手工艺"), .init(id: 2146, title: "解压手工"), .init(id: 2147, title: "DIY玩具"), .init(id: 2148, title: "其他手工")]),
    .init(id: 1022, title: "旅游出行", children: [.init(id: 2158, title: "旅游记录"), .init(id: 2159, title: "旅游攻略"), .init(id: 2160, title: "城市出行"), .init(id: 2161, title: "公共交通")]),
    .init(id: 1023, title: "三农", children: [.init(id: 2162, title: "农村种植"), .init(id: 2163, title: "赶海捕鱼"), .init(id: 2164, title: "打野采摘"), .init(id: 2165, title: "农业技术"), .init(id: 2166, title: "农村生活")]),
    .init(id: 1024, title: "动物", children: [.init(id: 2167, title: "猫"), .init(id: 2168, title: "狗"), .init(id: 2169, title: "小宠异宠"), .init(id: 2170, title: "野生动物·动物解说科普"), .init(id: 2171, title: "动物综合·二创")]),
    .init(id: 1025, title: "亲子", children: [.init(id: 2172, title: "孕产护理"), .init(id: 2173, title: "婴幼护理"), .init(id: 2174, title: "儿童才艺"), .init(id: 2175, title: "萌娃"), .init(id: 2176, title: "亲子互动"), .init(id: 2177, title: "亲子教育"), .init(id: 2178, title: "亲子综合")]),
    .init(id: 1026, title: "健康", children: [.init(id: 2179, title: "健康科普"), .init(id: 2180, title: "养生"), .init(id: 2181, title: "两性知识"), .init(id: 2182, title: "心理健康"), .init(id: 2183, title: "助眠视频·ASMR"), .init(id: 2184, title: "医疗保健综合")]),
    .init(id: 1027, title: "情感", children: [.init(id: 2185, title: "家庭关系"), .init(id: 2186, title: "恋爱关系"), .init(id: 2187, title: "人际关系"), .init(id: 2188, title: "自我成长")]),
    .init(id: 1028, title: "神秘学", children: [.init(id: 2189, title: "塔罗占卜"), .init(id: 2190, title: "星座占星"), .init(id: 2191, title: "传统玄学"), .init(id: 2192, title: "疗愈成长"), .init(id: 2193, title: "其他神秘学")]),
    .init(id: 1029, title: "vlog", children: [.init(id: 2194, title: "中外生活vlog"), .init(id: 2195, title: "学生vlog"), .init(id: 2196, title: "职业vlog"), .init(id: 2197, title: "其他vlog")]),
    .init(id: 1030, title: "生活兴趣", children: [.init(id: 2198, title: "休闲玩乐"), .init(id: 2199, title: "线下演出"), .init(id: 2200, title: "文玩文创"), .init(id: 2201, title: "潮玩玩具"), .init(id: 2202, title: "兴趣综合")]),
    .init(id: 1031, title: "生活经验", children: [.init(id: 2203, title: "生活技能"), .init(id: 2204, title: "办事流程"), .init(id: 2205, title: "婚嫁")]),
  ]
  static func parent(of id: Int) -> VideoRegion { all.first { $0.id == id || $0.children.contains { $0.id == id } } ?? all[0] }
}

#if os(macOS)
struct RegionSelector: View {
  @Bindable var store: Store
  var body: some View {
    let parent = VideoRegion.parent(of: store.selectedRegion)
    VStack(alignment: .leading, spacing: 14) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
        ForEach(VideoRegion.all) { region in
          Button { store.selectRegion(region.id) } label: {
            Text(region.title).font(.callout).frame(maxWidth: .infinity).padding(.vertical, 9)
              .background(parent.id == region.id ? biliPink.opacity(0.2) : .clear, in: .capsule)
          }.buttonStyle(.plain).accessibilityAddTraits(parent.id == region.id ? .isSelected : [])
        }
      }

    }.padding(16).floatingGlass(AppLayout.panelRadius)
  }
}

#endif

extension API {
  func regionVideos(_ id: Int, page: Int) async throws -> [Video] {
    do {
      let data = try await request("/x/web-interface/region/feed/rcmd",
        ["from_region": String(id), "display_id": String(page), "request_cnt": "15", "device": "web", "plat": "30"])
      return (data["archives"] as? [[String: Any]] ?? []).compactMap(Video.parse)
    } catch let error as BiliError where error.code == 62013 && page > 1 { return [] }
  }
}
