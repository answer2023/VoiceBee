/* global React, ReactDOM */
const {
  useEffect
} = React;
const Icon = ({
  name,
  size = 18,
  stroke = 1.6
}) => {
  const p = {
    width: size,
    height: size,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: stroke,
    strokeLinecap: "round",
    strokeLinejoin: "round"
  };
  switch (name) {
    case "mic":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("rect", {
        x: "9",
        y: "3",
        width: "6",
        height: "12",
        rx: "3"
      }), /*#__PURE__*/React.createElement("path", {
        d: "M5 11a7 7 0 0 0 14 0M12 18v3"
      }));
    case "globe":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("circle", {
        cx: "12",
        cy: "12",
        r: "9"
      }), /*#__PURE__*/React.createElement("path", {
        d: "M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"
      }));
    case "bolt":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("path", {
        d: "M13 2 4 14h7l-1 8 9-12h-7l1-8z"
      }));
    case "sparkle":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("path", {
        d: "M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8L12 3z"
      }));
    case "lock":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("rect", {
        x: "4",
        y: "11",
        width: "16",
        height: "10",
        rx: "2"
      }), /*#__PURE__*/React.createElement("path", {
        d: "M8 11V7a4 4 0 0 1 8 0v4"
      }));
    case "keyboard":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("rect", {
        x: "2",
        y: "6",
        width: "20",
        height: "12",
        rx: "2"
      }), /*#__PURE__*/React.createElement("path", {
        d: "M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"
      }));
    case "chip":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("rect", {
        x: "6",
        y: "6",
        width: "12",
        height: "12",
        rx: "2"
      }), /*#__PURE__*/React.createElement("path", {
        d: "M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"
      }));
    case "clock":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("circle", {
        cx: "12",
        cy: "12",
        r: "9"
      }), /*#__PURE__*/React.createElement("path", {
        d: "M12 7v5l3 2"
      }));
    case "book":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("path", {
        d: "M4 4.5A2.5 2.5 0 0 1 6.5 2H20v17H6.5A2.5 2.5 0 0 0 4 21.5v-17z"
      }));
    case "arrow-right":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("path", {
        d: "M5 12h14M13 6l6 6-6 6"
      }));
    case "download":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("path", {
        d: "M12 3v12m-5-5 5 5 5-5M4 21h16"
      }));
    case "translate":
      return /*#__PURE__*/React.createElement("svg", p, /*#__PURE__*/React.createElement("path", {
        d: "M3 5h10M8 3v2c0 4-2 8-5 10M5 9c0 3 4 5 8 5M14 21l4-10 4 10M16 17h6"
      }));
    default:
      return null;
  }
};
const Nav = () => /*#__PURE__*/React.createElement("nav", {
  className: "nav"
}, /*#__PURE__*/React.createElement("div", {
  className: "nav-inner"
}, /*#__PURE__*/React.createElement("a", {
  href: "index.html",
  className: "nav-logo"
}, /*#__PURE__*/React.createElement("span", {
  className: "nav-logo-mark"
}), "ClearSky"), /*#__PURE__*/React.createElement("div", {
  className: "nav-links"
}, /*#__PURE__*/React.createElement("a", {
  href: "voicebee.html",
  style: {
    color: "#fff"
  }
}, "VoiceBee"), /*#__PURE__*/React.createElement("a", {
  href: "jotbee.html"
}, "JotBee"), /*#__PURE__*/React.createElement("a", {
  href: "index.html#blog"
}, "Blog"), /*#__PURE__*/React.createElement("a", {
  href: "index.html#about"
}, "\u5173\u4E8E"))));
const SubNav = () => /*#__PURE__*/React.createElement("div", {
  className: "subnav"
}, /*#__PURE__*/React.createElement("div", {
  className: "subnav-inner"
}, /*#__PURE__*/React.createElement("span", {
  className: "subnav-name"
}, /*#__PURE__*/React.createElement("img", {
  src: "assets/voicebee-icon.png",
  alt: ""
}), " VoiceBee"), /*#__PURE__*/React.createElement("div", {
  className: "subnav-links"
}, /*#__PURE__*/React.createElement("a", {
  href: "#features"
}, "\u529F\u80FD"), /*#__PURE__*/React.createElement("a", {
  href: "#translate"
}, "\u7FFB\u8BD1"), /*#__PURE__*/React.createElement("a", {
  href: "#howto"
}, "\u4E0A\u624B"), /*#__PURE__*/React.createElement("a", {
  href: "#changelog"
}, "\u66F4\u65B0\u65E5\u5FD7"), /*#__PURE__*/React.createElement("a", {
  href: "#download"
}, "\u4E0B\u8F7D"))));
const Hero = () => /*#__PURE__*/React.createElement("section", {
  className: "section section-dark",
  style: {
    paddingBottom: "60px"
  }
}, /*#__PURE__*/React.createElement("div", {
  className: "section-inner center"
}, /*#__PURE__*/React.createElement("div", {
  className: "product-hero"
}, /*#__PURE__*/React.createElement("img", {
  src: "assets/voicebee-icon.png",
  alt: "VoiceBee",
  className: "product-hero-icon"
}), /*#__PURE__*/React.createElement("h1", null, "VoiceBee"), /*#__PURE__*/React.createElement("p", {
  className: "product-hero-tag"
}, "\u6309\u4F4F\u8BF4\u8BDD\uFF0C\u677E\u5F00\u8F93\u5165\u3002", /*#__PURE__*/React.createElement("br", null), "\u9009\u4E2D\u6587\u5B57\uFF0C\u4E00\u952E\u7FFB\u8BD1\u3002"), /*#__PURE__*/React.createElement("div", {
  className: "cta-buttons"
}, /*#__PURE__*/React.createElement("a", {
  href: "#download",
  className: "btn btn-primary"
}, /*#__PURE__*/React.createElement(Icon, {
  name: "download",
  size: 14
}), "Download for macOS"), /*#__PURE__*/React.createElement("a", {
  href: "#features",
  className: "btn btn-ghost"
}, "\u4E86\u89E3\u66F4\u591A")), /*#__PURE__*/React.createElement("div", {
  className: "product-hero-meta"
}, "v1.2.1 \xB7 macOS 14.0+ \xB7 \u5B8C\u5168\u514D\u8D39")), /*#__PURE__*/React.createElement("div", {
  className: "vb-hero-panel"
}, /*#__PURE__*/React.createElement("div", {
  className: "vb-hero-text"
}, "\u4ECA\u5929\u7684\u5929\u6C14\u771F\u4E0D\u9519\uFF0C\u9002\u5408\u51FA\u53BB\u8D70\u8D70", /*#__PURE__*/React.createElement("span", {
  className: "mock-voicebee-cursor"
})), /*#__PURE__*/React.createElement("div", {
  className: "vb-hero-bottom"
}, /*#__PURE__*/React.createElement("div", {
  className: "mock-voicebee-wave"
}, /*#__PURE__*/React.createElement("span", null), /*#__PURE__*/React.createElement("span", null), /*#__PURE__*/React.createElement("span", null), /*#__PURE__*/React.createElement("span", null), /*#__PURE__*/React.createElement("span", null), /*#__PURE__*/React.createElement("span", null), /*#__PURE__*/React.createElement("span", null), /*#__PURE__*/React.createElement("span", null)), /*#__PURE__*/React.createElement("div", {
  className: "mock-voicebee-kbd"
}, "fn \u6309\u4F4F\u8BF4\u8BDD")))));
const FeatureBlock = ({
  eyebrow,
  title,
  desc,
  dark
}) => /*#__PURE__*/React.createElement("section", {
  className: `section ${dark ? "section-dark" : "section-white"}`
}, /*#__PURE__*/React.createElement("div", {
  className: "section-inner center"
}, /*#__PURE__*/React.createElement("div", {
  className: "feature-block"
}, eyebrow && /*#__PURE__*/React.createElement("div", {
  className: "eyebrow"
}, eyebrow), /*#__PURE__*/React.createElement("h2", null, title), /*#__PURE__*/React.createElement("p", {
  className: "subtitle"
}, desc))));
const FeaturesGrid = () => {
  const items = [{
    icon: "mic",
    title: "实时识别",
    desc: "流式语音转文字，边说边出字，五种语言。"
  }, {
    icon: "keyboard",
    title: "全局可用",
    desc: "任何 App，按住快捷键即可语音输入。"
  }, {
    icon: "translate",
    title: "一键翻译",
    desc: "选中文字按 ⌥T，中英自动识别，即刻翻译。"
  }, {
    icon: "sparkle",
    title: "AI 润色",
    desc: "修正同音字、补标点、去口头禅、调语序。"
  }, {
    icon: "bolt",
    title: "双模式",
    desc: "即时上屏 / 润色上屏，双击 Fn 切换。"
  }, {
    icon: "globe",
    title: "浮窗预览",
    desc: "光标附近实时显示，毛玻璃设计。"
  }, {
    icon: "chip",
    title: "多引擎",
    desc: "Ollama · Claude · DeepSeek · Gemini · OpenAI。"
  }, {
    icon: "book",
    title: "历史记录",
    desc: "最近 50 条语音记录，随时回看和重新输入。"
  }, {
    icon: "lock",
    title: "本地优先",
    desc: "语音识别基于 Apple 本地框架，不上传服务器。"
  }];
  return /*#__PURE__*/React.createElement("section", {
    id: "features",
    className: "section section-light"
  }, /*#__PURE__*/React.createElement("div", {
    className: "section-inner"
  }, /*#__PURE__*/React.createElement("div", {
    className: "feature-block"
  }, /*#__PURE__*/React.createElement("div", {
    className: "eyebrow"
  }, "\u529F\u80FD\u4E00\u89C8"), /*#__PURE__*/React.createElement("h2", null, "\u6BCF\u4E00\u4E2A\u7EC6\u8282\uFF0C\u90FD\u4E3A\u6548\u7387\u800C\u751F\u3002")), /*#__PURE__*/React.createElement("div", {
    className: "features-grid"
  }, items.map(it => /*#__PURE__*/React.createElement("div", {
    className: "feature-card",
    key: it.title
  }, /*#__PURE__*/React.createElement("div", {
    className: "feature-card-icon"
  }, /*#__PURE__*/React.createElement(Icon, {
    name: it.icon,
    size: 18
  })), /*#__PURE__*/React.createElement("h3", null, it.title), /*#__PURE__*/React.createElement("p", null, it.desc))))));
};
const Steps = () => /*#__PURE__*/React.createElement("section", {
  id: "howto",
  className: "section section-white"
}, /*#__PURE__*/React.createElement("div", {
  className: "section-inner"
}, /*#__PURE__*/React.createElement("div", {
  className: "feature-block"
}, /*#__PURE__*/React.createElement("div", {
  className: "eyebrow"
}, "\u4E0A\u624B\u5373\u7528"), /*#__PURE__*/React.createElement("h2", null, "\u4E09\u6B65\u5F00\u59CB\u7528\u8BED\u97F3\u5199\u5B57\u3002")), /*#__PURE__*/React.createElement("div", {
  className: "steps"
}, /*#__PURE__*/React.createElement("div", {
  className: "step"
}, /*#__PURE__*/React.createElement("div", {
  className: "step-num-circle"
}, "1"), /*#__PURE__*/React.createElement("div", {
  className: "step-text"
}, /*#__PURE__*/React.createElement("h3", null, "\u6309\u4F4F\u5FEB\u6377\u952E\u8BF4\u8BDD"), /*#__PURE__*/React.createElement("p", null, "\u6D6E\u7A97\u81EA\u52A8\u51FA\u73B0\u5728\u5149\u6807\u9644\u8FD1\uFF0C\u5B9E\u65F6\u663E\u793A\u8BC6\u522B\u6587\u5B57\u3002"))), /*#__PURE__*/React.createElement("div", {
  className: "step"
}, /*#__PURE__*/React.createElement("div", {
  className: "step-num-circle"
}, "2"), /*#__PURE__*/React.createElement("div", {
  className: "step-text"
}, /*#__PURE__*/React.createElement("h3", null, "\u677E\u5F00\uFF0C\u6587\u5B57\u4E0A\u5C4F"), /*#__PURE__*/React.createElement("p", null, "\u6587\u5B57\u7ACB\u5373\u8F93\u5165\u5230\u5149\u6807\u4F4D\u7F6E\u3002\u53CC\u51FB Fn \u5207\u6362\u5373\u65F6 / \u6DA6\u8272\u6A21\u5F0F\u3002"))), /*#__PURE__*/React.createElement("div", {
  className: "step"
}, /*#__PURE__*/React.createElement("div", {
  className: "step-num-circle"
}, "3"), /*#__PURE__*/React.createElement("div", {
  className: "step-text"
}, /*#__PURE__*/React.createElement("h3", null, "\u9009\u4E2D\u6587\u5B57\uFF0C\u2325T \u7FFB\u8BD1"), /*#__PURE__*/React.createElement("p", null, "\u4E2D\u82F1\u81EA\u52A8\u8BC6\u522B\u65B9\u5411\u3002\u7FFB\u8BD1\u7ED3\u679C\u76F4\u63A5\u663E\u793A\u5728\u6D6E\u7A97\u4E2D\u3002"))))));
const Changelog = () => /*#__PURE__*/React.createElement("section", {
  id: "changelog",
  className: "section section-light"
}, /*#__PURE__*/React.createElement("div", {
  className: "section-inner"
}, /*#__PURE__*/React.createElement("div", {
  className: "feature-block"
}, /*#__PURE__*/React.createElement("div", {
  className: "eyebrow"
}, "\u66F4\u65B0\u65E5\u5FD7"), /*#__PURE__*/React.createElement("h2", null, "\u6301\u7EED\u5728\u6253\u78E8\u3002")), /*#__PURE__*/React.createElement("div", {
  className: "changelog"
}, /*#__PURE__*/React.createElement("div", {
  className: "changelog-entry"
}, /*#__PURE__*/React.createElement("h3", null, "v1.2.1 ", /*#__PURE__*/React.createElement("span", {
  className: "changelog-date"
}, "2026.05.04")), /*#__PURE__*/React.createElement("ul", null, /*#__PURE__*/React.createElement("li", null, "\u5F55\u97F3\u6D6E\u7A97\u89C6\u89C9\u7B80\u5316\uFF0C\u53BB\u9664\u591A\u4F59\u9634\u5F71"), /*#__PURE__*/React.createElement("li", null, "4 \u79CD\u8F93\u51FA\u98CE\u683C\u73B0\u5728\u7528 4 \u79CD\u989C\u8272\u533A\u5206"), /*#__PURE__*/React.createElement("li", null, "\u53CC\u51FB Fn \u5207\u6362\u98CE\u683C\u65F6\uFF0C\u63D0\u793A\u6D6E\u7A97\u7684\u989C\u8272\u4E0E\u76EE\u6807\u98CE\u683C\u4E00\u81F4"))), /*#__PURE__*/React.createElement("div", {
  className: "changelog-entry"
}, /*#__PURE__*/React.createElement("h3", null, "v1.1.0 ", /*#__PURE__*/React.createElement("span", {
  className: "changelog-date"
}, "2026.04.14")), /*#__PURE__*/React.createElement("ul", null, /*#__PURE__*/React.createElement("li", null, "\u6DA6\u8272\u6A21\u5F0F\u5168\u9762\u5347\u7EA7 \u2014 \u6D41\u5F0F\u54CD\u5E94\uFF0C\u9996\u5B57 ~0.5 \u79D2\u51FA\u73B0"), /*#__PURE__*/React.createElement("li", null, "\u6D6E\u7A97\u5B9E\u65F6\u663E\u793A AI \u6DA6\u8272\u8FC7\u7A0B"), /*#__PURE__*/React.createElement("li", null, "\u652F\u6301 Ollama / Claude / DeepSeek / Gemini \u5168\u5F15\u64CE\u6D41\u5F0F\u8F93\u51FA"), /*#__PURE__*/React.createElement("li", null, "SSE \u89E3\u6790\u4F18\u5316\uFF0C\u517C\u5BB9\u6240\u6709\u4E3B\u6D41 AI \u534F\u8BAE"))), /*#__PURE__*/React.createElement("div", {
  className: "changelog-entry"
}, /*#__PURE__*/React.createElement("h3", null, "v1.0.0 ", /*#__PURE__*/React.createElement("span", {
  className: "changelog-date"
}, "2026.04.12")), /*#__PURE__*/React.createElement("ul", null, /*#__PURE__*/React.createElement("li", null, "\u65B0\u589E\u7FFB\u8BD1\u529F\u80FD \u2014 \u9009\u4E2D\u6587\u5B57\u6309\u5FEB\u6377\u952E\u5373\u53EF\u7FFB\u8BD1"), /*#__PURE__*/React.createElement("li", null, "\u7FFB\u8BD1\u5F15\u64CE\u72EC\u7ACB\u914D\u7F6E\uFF0C\u652F\u6301\u591A\u5F15\u64CE"), /*#__PURE__*/React.createElement("li", null, "\u5373\u65F6\u6A21\u5F0F AI \u6DA6\u8272\u4F18\u5316"), /*#__PURE__*/React.createElement("li", null, "\u8BBE\u7F6E\u754C\u9762\u65B0\u589E\u7FFB\u8BD1 Tab"))), /*#__PURE__*/React.createElement("div", {
  className: "changelog-entry"
}, /*#__PURE__*/React.createElement("h3", null, "v0.3.0 ", /*#__PURE__*/React.createElement("span", {
  className: "changelog-date"
}, "2026.04.08")), /*#__PURE__*/React.createElement("ul", null, /*#__PURE__*/React.createElement("li", null, "\u83DC\u5355\u680F\u4EA4\u4E92\u4F18\u5316"), /*#__PURE__*/React.createElement("li", null, "\u4FEE\u590D\u5185\u5B58\u6CC4\u6F0F\u548C\u53CC\u91CD\u89E6\u53D1\u95EE\u9898"), /*#__PURE__*/React.createElement("li", null, "Fn \u952E\u4E0D\u518D\u5E72\u6270\u5176\u4ED6 App"))), /*#__PURE__*/React.createElement("div", {
  className: "changelog-entry"
}, /*#__PURE__*/React.createElement("h3", null, "v0.1.0 ", /*#__PURE__*/React.createElement("span", {
  className: "changelog-date"
}, "2026.04.03")), /*#__PURE__*/React.createElement("ul", null, /*#__PURE__*/React.createElement("li", null, "\u9996\u4E2A\u53D1\u5E03\u7248\u672C"), /*#__PURE__*/React.createElement("li", null, "\u6D41\u5F0F\u5B9E\u65F6\u8BED\u97F3\u8BC6\u522B + \u5168\u5C40\u5FEB\u6377\u952E + \u53CC\u6A21\u5F0F"), /*#__PURE__*/React.createElement("li", null, "\u591A AI \u5F15\u64CE\u652F\u6301\uFF0C\u6D6E\u7A97\u8DDF\u968F\u5149\u6807"))))));
const CTA = () => /*#__PURE__*/React.createElement("section", {
  id: "download",
  className: "section section-dark",
  style: {
    padding: "100px 0"
  }
}, /*#__PURE__*/React.createElement("div", {
  className: "section-inner center"
}, /*#__PURE__*/React.createElement("div", {
  className: "eyebrow"
}, "\u73B0\u5728\u5C31\u4E0B\u8F7D"), /*#__PURE__*/React.createElement("h2", {
  className: "headline-section"
}, "\u514D\u8D39\u7528\u8D77\u6765\u3002"), /*#__PURE__*/React.createElement("p", {
  className: "subtitle",
  style: {
    margin: "16px auto 0"
  }
}, "\u65E0\u5185\u8D2D\uFF0C\u65E0\u5E7F\u544A\uFF0C\u65E0\u8D26\u53F7\u3002"), /*#__PURE__*/React.createElement("div", {
  className: "cta-buttons"
}, /*#__PURE__*/React.createElement("a", {
  href: "https://github.com/answer2023/VoiceBee/releases/download/v1.2.1/VoiceBee-1.2.1.dmg",
  className: "btn btn-primary"
}, /*#__PURE__*/React.createElement(Icon, {
  name: "download",
  size: 14
}), "Download for macOS"), /*#__PURE__*/React.createElement("a", {
  href: "index.html",
  className: "btn btn-ghost"
}, "\u4E86\u89E3 ClearSky"))));
const Footer = () => /*#__PURE__*/React.createElement("footer", {
  className: "footer"
}, /*#__PURE__*/React.createElement("div", {
  className: "footer-inner"
}, /*#__PURE__*/React.createElement("div", {
  className: "footer-brand-col"
}, /*#__PURE__*/React.createElement("div", {
  className: "footer-brand"
}, "ClearSky"), /*#__PURE__*/React.createElement("p", {
  className: "footer-tagline"
}, "\u72EC\u7ACB\u5DE5\u4F5C\u5BA4\u3002\u4E00\u4EBA + AI\uFF0C\u505A\u81EA\u5DF1\u9700\u8981\u7684\u5DE5\u5177\u3002")), /*#__PURE__*/React.createElement("div", {
  className: "footer-col"
}, /*#__PURE__*/React.createElement("h4", null, "Products"), /*#__PURE__*/React.createElement("a", {
  href: "voicebee.html"
}, "VoiceBee"), /*#__PURE__*/React.createElement("a", {
  href: "jotbee.html"
}, "JotBee")), /*#__PURE__*/React.createElement("div", {
  className: "footer-col"
}, /*#__PURE__*/React.createElement("h4", null, "Resources"), /*#__PURE__*/React.createElement("a", {
  href: "index.html#blog"
}, "Blog"), /*#__PURE__*/React.createElement("a", {
  href: "index.html#about"
}, "\u5173\u4E8E")), /*#__PURE__*/React.createElement("div", {
  className: "footer-col"
}, /*#__PURE__*/React.createElement("h4", null, "Contact"), /*#__PURE__*/React.createElement("a", {
  href: "privacy.html"
}, "Privacy"), /*#__PURE__*/React.createElement("a", {
  href: "mailto:hi@tangzhihong.com"
}, "Email"))), /*#__PURE__*/React.createElement("div", {
  className: "footer-legal"
}, /*#__PURE__*/React.createElement("span", null, "Copyright \xA9 2026 ClearSky. All rights reserved."), /*#__PURE__*/React.createElement("a", {
  href: "privacy.html"
}, "\u9690\u79C1\u653F\u7B56")));
const App = () => /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(Nav, null), /*#__PURE__*/React.createElement(SubNav, null), /*#__PURE__*/React.createElement("main", {
  id: "main"
}, /*#__PURE__*/React.createElement(Hero, null), /*#__PURE__*/React.createElement(FeatureBlock, {
  eyebrow: "\u5B9E\u65F6\u8BC6\u522B",
  title: "\u8FB9\u8BF4\u8FB9\u51FA\u5B57\u3002",
  desc: "\u6D41\u5F0F\u8BED\u97F3\u8F6C\u6587\u5B57\uFF0C\u57FA\u4E8E Apple Speech \u6846\u67B6\u3002\u5EF6\u8FDF\u6781\u4F4E\uFF0C\u652F\u6301\u4E2D\u6587\u3001\u82F1\u8BED\u3001\u65E5\u8BED\u3001\u97E9\u8BED\u3001\u7E41\u4F53\u4E2D\u6587\u3002"
}), /*#__PURE__*/React.createElement(FeatureBlock, {
  eyebrow: "\u9009\u4E2D\u5373\u7FFB\u8BD1",
  title: "\u4E00\u952E\u4E2D\u82F1\u4E92\u8F6C\u3002",
  desc: "\u9009\u4E2D\u4EFB\u610F\u6587\u5B57\uFF0C\u6309\u4E0B \u2325T\uFF0C\u7FFB\u8BD1\u7ED3\u679C\u5373\u523B\u51FA\u73B0\u3002\u4E2D\u82F1\u81EA\u52A8\u8BC6\u522B\uFF0C\u4E5F\u652F\u6301\u65E5\u8BED\u76EE\u6807\u8BED\u8A00\u3002\u7FFB\u8BD1\u5F15\u64CE\u72EC\u7ACB\u914D\u7F6E\u3002",
  dark: true
}), /*#__PURE__*/React.createElement(FeatureBlock, {
  eyebrow: "\u9690\u79C1",
  title: "\u4F60\u7684\u58F0\u97F3\u4E0D\u4F1A\u88AB\u4E0A\u4F20\u3002",
  desc: "\u8BED\u97F3\u8BC6\u522B\u57FA\u4E8E Apple \u672C\u5730\u6846\u67B6\uFF0C\u4E0D\u7ECF\u8FC7\u7B2C\u4E09\u65B9\u670D\u52A1\u5668\u3002AI \u6DA6\u8272\u548C\u7FFB\u8BD1\u4F7F\u7528\u4F60\u81EA\u5DF1\u7684 API Key\uFF0C\u8D39\u7528\u5B8C\u5168\u900F\u660E\u3002"
}), /*#__PURE__*/React.createElement(FeaturesGrid, null), /*#__PURE__*/React.createElement(Steps, null), /*#__PURE__*/React.createElement(Changelog, null), /*#__PURE__*/React.createElement(CTA, null)), /*#__PURE__*/React.createElement(Footer, null));
ReactDOM.createRoot(document.getElementById("root")).render(/*#__PURE__*/React.createElement(App, null));