enum EmojiSuggestions {
    // Match complete words only. A substring match would suggest 🐱 for 猫眼 or ☀️ for 太阳穴.
    private static let byWord: [String: String] = {
        let associations: [(String, String)] = [
            ("👋", "你好 嗨 哈喽 打招呼 再见 拜拜"),
            ("😊", "高兴 開心 开心 愉快 微笑 笑容 喜悦 喜悅"),
            ("😂", "哈哈 哈哈哈 笑哭 大笑 笑死 笑死了"),
            ("🤣", "爆笑 捧腹 搞笑 太好笑了"),
            ("❤️", "爱 愛 爱你 愛你 爱心 愛心 喜欢 喜歡 心动 心動"),
            ("🥰", "可爱 可愛 宠爱 寵愛"),
            ("😘", "亲亲 親親 飞吻 飛吻"),
            ("😢", "哭 哭泣 流泪 流淚 伤心 傷心 难过 難過"),
            ("😡", "生气 生氣 愤怒 憤怒 气愤 氣憤"),
            ("😮", "惊讶 驚訝 吃惊 吃驚 震惊 震驚"),
            ("🤔", "思考 想想 疑惑 考虑 考慮"),
            ("😴", "睡觉 睡覺 睡了 困了 打瞌睡 晚安"),
            ("🙏", "谢谢 謝謝 感谢 感謝 拜托 拜託 感恩"),
            ("👍", "点赞 點讚 赞 讚 好棒 真棒 厉害 厲害"),
            ("👏", "鼓掌 掌声 掌聲 喝彩"),
            ("🤝", "握手 合作 达成 達成"),
            ("🎉", "庆祝 慶祝 恭喜 祝贺 祝賀"),
            ("🎂", "蛋糕 生日 生日快乐 生日快樂 生日蛋糕"),
            ("🎁", "礼物 禮物 送礼 送禮"),
            ("🎆", "烟花 煙花 焰火"),
            ("🏆", "冠军 冠軍 奖杯 獎盃 夺冠 奪冠"),
            ("💪", "加油 努力 坚持 堅持"),
            ("🐱", "猫 貓 小猫 小貓 猫咪 貓咪"),
            ("🐶", "狗 小狗 狗狗 汪汪"),
            ("🐼", "熊猫 熊貓 大熊猫 大熊貓"),
            ("🐰", "兔 兔子 小兔 白兔"),
            ("🐭", "老鼠 小老鼠"),
            ("🐮", "牛 黄牛 黃牛 奶牛"),
            ("🐯", "虎 老虎"),
            ("🐵", "猴 猴子"),
            ("🐷", "猪 豬 小猪 小豬"),
            ("🐸", "青蛙 蛤蟆"),
            ("🦋", "蝴蝶"),
            ("🐝", "蜜蜂"),
            ("🐟", "鱼 魚 小鱼 小魚"),
            ("🐉", "龙 龍"),
            ("🌹", "玫瑰 玫瑰花"),
            ("🌸", "樱花 櫻花"),
            ("🌻", "向日葵"),
            ("🌲", "松树 松樹"),
            ("🌈", "彩虹"),
            ("☀️", "太阳 太陽 晴天 阳光 陽光"),
            ("🌙", "月亮 月牙"),
            ("⭐️", "星星 星光"),
            ("☁️", "云 雲 云朵 雲朵"),
            ("🌧️", "下雨 雨天"),
            ("❄️", "雪 雪花 下雪"),
            ("🔥", "火 火焰 着火"),
            ("⚡️", "闪电 閃電 雷电 雷電"),
            ("🌊", "海浪 浪花"),
            ("☕️", "咖啡 拿铁 拿鐵 卡布奇诺 卡布奇諾"),
            ("🍵", "茶 绿茶 綠茶 茶杯"),
            ("🧋", "奶茶 珍珠奶茶"),
            ("🍺", "啤酒"),
            ("🍷", "红酒 紅酒 葡萄酒"),
            ("🥂", "干杯 乾杯"),
            ("🍎", "苹果 蘋果 红苹果 紅蘋果"),
            ("🍉", "西瓜"),
            ("🍌", "香蕉"),
            ("🍓", "草莓"),
            ("🍇", "葡萄"),
            ("🍑", "桃子"),
            ("🍊", "橘子 橙子"),
            ("🍒", "樱桃 櫻桃"),
            ("🍍", "菠萝 菠蘿 凤梨 鳳梨"),
            ("🥭", "芒果"),
            ("🥑", "牛油果 酪梨"),
            ("🍚", "米饭 米飯 白饭 白飯"),
            ("🍜", "面条 麵條 拉面 拉麵"),
            ("🥟", "饺子 餃子 水饺 水餃"),
            ("🍔", "汉堡 漢堡"),
            ("🍕", "披萨 披薩 比萨 比薩"),
            ("🍟", "薯条 薯條"),
            ("🍣", "寿司 壽司"),
            ("🍦", "冰淇淋 冰激凌"),
            ("🍫", "巧克力"),
            ("📱", "手机 手機"),
            ("💻", "电脑 電腦 笔记本电脑 筆記本電腦"),
            ("⌨️", "键盘 鍵盤"),
            ("📷", "相机 相機 拍照 摄影 攝影"),
            ("🎵", "音乐 音樂 歌曲 音符"),
            ("🪈", "笛子 笛 長笛 长笛 短笛"),
            ("🎣", "钓鱼 釣魚 垂钓 垂釣"),
            ("📚", "书籍 書籍 读书 讀書"),
            ("💡", "灯泡 燈泡 灵感 靈感"),
            ("⏰", "闹钟 鬧鐘"),
            ("❤️‍🩹", "疗愈 療癒"),
            ("🏠", "房子 回家"),
            ("🏫", "学校 學校"),
            ("🏥", "医院 醫院"),
            ("🚗", "汽车 汽車 小汽车 小汽車"),
            ("✈️", "飞机 飛機"),
            ("🚆", "火车 火車"),
            ("🚇", "地铁 地鐵"),
            ("🚲", "自行车 自行車 单车 單車"),
            ("🧳", "行李 箱子 行李箱"),
            ("🏖️", "沙滩 沙灘 海滩 海灘"),
            ("⚽️", "足球"),
            ("🏀", "篮球 籃球"),
            ("🏸", "羽毛球"),
            ("🎾", "网球 網球"),
            ("🏓", "乒乓球"),
            ("🏊", "游泳"),
            ("🤿", "潜水 潛水 水肺潜水 水肺潛水 浮潜 浮潛 自由潜水 自由潛水"),
            ("🏃", "跑步"),
            ("🎮", "游戏 遊戲 手柄")
        ]
        var index: [String: String] = [:]
        for (emoji, words) in associations {
            for word in words.split(separator: " ") { index[String(word)] = emoji }
        }
        return index
    }()

    static func adding(to candidates: [Candidate], mode: Composition.Mode, code: String, pageSize: Int) -> [Candidate] {
        let expandsExactMatches = mode == .wubi && code.count == 4
        if mode == .wubi {
            if code.count == 1 { return candidates }
            if expandsExactMatches, let first = code.first, Lexicon.roots[first] != nil, code.allSatisfy({ $0 == first }) {
                return candidates
            }
        }
        guard let first = candidates.first, !first.isCloud else { return candidates }

        var seen = Set<String>()
        var suggestions: [Candidate] = []
        for (index, candidate) in candidates.enumerated() {
            if index > 0 {
                guard expandsExactMatches else { break }
                guard candidate.source == nil, candidate.hint.isEmpty else { continue }
            }
            let emoji = byWord[candidate.word] ?? EmojiAnnotations.emoji(for: candidate.word)
            guard let emoji, seen.insert(emoji).inserted,
                  !candidates.contains(where: { $0.word == emoji }) else { continue }
            suggestions.append(Candidate(emoji, source: .emojiSuggestion))
        }
        guard !suggestions.isEmpty else { return candidates }

        var result = candidates
        let firstCloud = candidates.firstIndex(where: \.isCloud) ?? candidates.count
        result.insert(contentsOf: suggestions, at: min(3, pageSize - 1, firstCloud))
        return result
    }
}
