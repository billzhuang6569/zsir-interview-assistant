import React, { useEffect, useState, useRef } from "react";
import {
  Monitor,
  VideoCamera,
  Microphone,
  SpeakerHigh,
  HardDrives,
  Stop,
  Play,
  Image as ImageIcon,
  Trash,
  ArrowsOut,
  ArrowLeft,
  CheckCircle,
  WarningCircle,
  WifiSlash,
  X,
  FolderOpen,
  Users,
  SlidersHorizontal,
} from "@phosphor-icons/react";
import { read, send } from "./store";
import { duration, frameTimes } from "./model.mjs";
const labels = {
  trial: "试录中",
  ready: "准备就绪",
  countdown: "即将开始",
  recording: "正在录制",
  saving: "正在保存",
  saved: "已保存",
  save_failed: "保存失败",
  ending: "正在结束任务",
  closed: "任务已结束",
};
const clock = (n) =>
  `${Math.floor(n / 3600)}`.padStart(2, "0") +
  ":" +
  `${Math.floor(n / 60) % 60}`.padStart(2, "0") +
  ":" +
  `${n % 60}`.padStart(2, "0");
const asset = (t) => `/assets/${t === "camera" ? "guest" : "desktop"}.jpg`;
function Modal({ title, children, onClose }) {
  const ref = useRef();
  useEffect(() => {
    const previous = document.activeElement;
    ref.current.showModal();
    return () => previous?.focus();
  }, []);
  return (
    <dialog ref={ref} onCancel={onClose}>
      <header>
        <h2>{title}</h2>
        <button className="icon" aria-label="关闭弹窗" onClick={onClose}>
          <X />
        </button>
      </header>
      {children}
    </dialog>
  );
}
function Meter({ type, active }) {
  const Icon = type === "camera" ? Microphone : SpeakerHigh;
  return (
    <div className="meter">
      <Icon size={23} />
      <span>{type === "camera" ? "话筒音量" : "系统声音"}</span>
      <meter
        min="0"
        max="100"
        value={active ? (type === "camera" ? 52 : 64) : 0}
        aria-label={type === "camera" ? "模拟话筒音量" : "模拟系统音量"}
      />
      <small>{active ? "-12 dB" : "—"}</small>
    </div>
  );
}
export function App() {
  const [s, setS] = useState(read),
    [now, setNow] = useState(Date.now()),
    [modal, setModal] = useState(null),
    [tab, setTab] = useState("control"),
    [selectedTake, setSelectedTake] = useState(null),
    [track, setTrack] = useState("desktop"),
    [page, setPage] = useState(0),
    [zoom, setZoom] = useState(null),
    [notice, setNotice] = useState(""),
    [expanded, setExpanded] = useState(false),
    [people, setPeople] = useState(1);
  const guest = new URLSearchParams(location.search).get("view") === "guest";
  const [actor] = useState(() =>
    guest ? "嘉宾本机" : `操作员${Math.floor(Math.random() * 90) + 10}`,
  );
  const alive = !["ending", "closed"].includes(s.phase) && !s.endRequested;
  const ready = ["ready", "saved"].includes(s.phase);
  const remoteBlocked = !guest && !s.connected;
  const elapsed = duration(s, remoteBlocked ? s.disconnectedAt || now : now);
  useEffect(() => {
    const update = () => setS(read());
    window.addEventListener("storage", update);
    window.addEventListener("prototype-change", update);
    const t = setInterval(() => {
      const time = Date.now();
      setNow(time);
      const current = read();
      if (
        (["trial", "countdown", "saving", "ending"].includes(current.phase) &&
          time >= current.deadline) ||
        (current.phase === "recording" &&
          current.connected &&
          time - (current.previewAt || 0) >= 5000)
      )
        send({ type: "tick", expected: current.version });
    }, 250);
    return () => {
      clearInterval(t);
      window.removeEventListener("storage", update);
      window.removeEventListener("prototype-change", update);
    };
  }, []);
  useEffect(() => {
    const id = crypto.randomUUID();
    const key = "zsir-presence-" + id;
    const heartbeat = () => {
      localStorage.setItem(key, JSON.stringify({ at: Date.now(), guest }));
      let n = 0;
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k?.startsWith("zsir-presence-")) {
          try {
            const p = JSON.parse(localStorage.getItem(k));
            if (!p.guest && Date.now() - p.at < 7000) n++;
          } catch {}
        }
      }
      setPeople(n);
    };
    heartbeat();
    const t = setInterval(heartbeat, 2000);
    return () => {
      clearInterval(t);
      localStorage.removeItem(key);
    };
  }, []);
  useEffect(() => {
    if (!notice) return;
    const t = setTimeout(() => setNotice(""), 3500);
    return () => clearTimeout(t);
  }, [notice]);
  useEffect(() => {
    if (s.endRequested) {
      setModal(null);
      setTab("control");
      setZoom(null);
    }
  }, [s.endRequested]);
  async function act(type, extra = {}) {
    const next = await send({
      type,
      actor,
      remote: !guest,
      expected: s.version,
      ...extra,
    });
    if (next.version === s.version && !["tick"].includes(type))
      setNotice("状态已更新或当前操作不可用，请重试");
  }
  const end = () => setModal("end");
  const startStop = () =>
    act(
      s.phase === "recording"
        ? "stop"
        : s.phase === "countdown"
          ? "cancel"
          : "start",
    );
  const primary = (
    <button
      className={s.phase === "recording" ? "primary red" : "primary"}
      disabled={
        remoteBlocked ||
        !alive ||
        (!ready && !["recording", "countdown"].includes(s.phase)) ||
        (ready && !Object.values(s.tracks).some(Boolean))
      }
      onClick={startStop}
    >
      {s.phase === "recording" ? (
        <Stop weight="fill" />
      ) : (
        <Play weight="fill" />
      )}
      {s.phase === "recording"
        ? "停止录制"
        : s.phase === "countdown"
          ? "取消倒计时"
          : "开始录制"}
    </button>
  );
  const toolbar = (
    <div className="demo-tools">
      <span>交互演示 · 模拟数据，无真实录制或卸载</span>
      <div>
        <button onClick={() => act("demo", { remote: false })}>
          载入录制示例
        </button>
        <button onClick={() => act("network", { remote: false })}>
          {s.connected ? "模拟断网" : "恢复网络"}
        </button>
        <button
          aria-pressed={s.failSave}
          onClick={() => act("failure", { remote: false })}
        >
          {s.failSave ? "故障已开启" : "模拟保存失败"}
        </button>
        <button
          onClick={() => {
            setModal("reset");
          }}
        >
          重置演示
        </button>
      </div>
    </div>
  );
  const statusPanel = (
    <>
      {s.phase === "trial" && (
        <div className="status-message" role="status">
          试录中 · 请说话并播放声音（约10秒）
        </div>
      )}
      {s.phase === "countdown" && (
        <div className="status-message">
          <strong>{Math.max(1, Math.ceil((s.deadline - now) / 1000))}</strong>
          <span>客户端倒计时 · 可取消</span>
        </div>
      )}
      {s.phase === "saving" && (
        <div className="status-message" role="status">
          <span>正在封装并检查两路素材，请稍候…</span>
        </div>
      )}
      {s.phase === "save_failed" && (
        <div className="alert" role="alert">
          <WarningCircle />
          保存失败（模拟），原始分段已保留
          {s.endRequested ? "，采集与远程控制已关闭" : ""}。
          <button onClick={() => act("retry", { remote: false })}>
            重试保存
          </button>
        </div>
      )}
      {s.phase === "ending" && (
        <div className="status-message" role="status">
          <CheckCircle />
          <span>素材已保留 · 授权已撤销 · 正在模拟清理与卸载…</span>
        </div>
      )}
      {s.phase === "closed" && (
        <div className="status-message" role="status">
          <CheckCircle />
          <span>模拟卸载完成 · 嘉宾端已关闭 · 素材已保留</span>
        </div>
      )}
    </>
  );
  return (
    <div className={guest ? "app guest-app" : "app"}>
      {guest ? (
        <>
          <div className="guest-desktop">
            <p className="guest-hint">嘉宾桌面演示</p>
            <p className="guest-caption">
              录制时，只留右上角的小窗。
              <br />
              不会访问你的摄像头、麦克风或桌面。
            </p>
            {s.phase !== "closed" ? (
              <section className="guest-widget" aria-label="嘉宾录制小窗">
                <div className="widget-status">
                  <span
                    className={
                      s.phase === "recording" ? "record-dot" : "ready-dot"
                    }
                  ></span>
                  <strong>{labels[s.phase]}</strong>
                  <time>
                    {s.phase === "countdown"
                      ? `${Math.max(1, Math.ceil((s.deadline - now) / 1000))}秒`
                      : clock(elapsed)}
                  </time>
                  <button
                    className="icon"
                    aria-label="展开设置"
                    onClick={() => setExpanded(!expanded)}
                  >
                    <SlidersHorizontal size={17} />
                  </button>
                </div>
                <div className="widget-tracks">
                  <span>{s.tracks.camera ? "摄像头已选" : "摄像头关闭"}</span>
                  <span>{s.tracks.desktop ? "桌面已选" : "桌面关闭"}</span>
                </div>
                <div className="widget-actions">
                  <button
                    disabled={
                      !alive ||
                      (!ready && !["recording", "countdown"].includes(s.phase))
                    }
                    onClick={startStop}
                  >
                    {s.phase === "recording"
                      ? "停止录制"
                      : s.phase === "countdown"
                        ? "取消倒计时"
                        : "开始录制"}
                  </button>
                  <button
                    className="danger-text"
                    disabled={!alive}
                    onClick={end}
                  >
                    结束任务
                  </button>
                </div>
              </section>
            ) : (
              <div className="guest-closed">
                <CheckCircle size={32} />
                <h2>任务已结束</h2>
                <p>
                  嘉宾小窗已关闭，采访素材保留。
                  <br />
                  这是模拟结果，没有卸载本机程序。
                </p>
              </div>
            )}
            {expanded && s.phase !== "closed" && (
              <section className="guest-settings">
                <header>
                  <h2>录制设置</h2>
                  <button
                    className="icon"
                    aria-label="收起设置"
                    onClick={() => setExpanded(false)}
                  >
                    <X />
                  </button>
                </header>
                <p>本次允许共享控制台查看画面、控制录制及结束任务卸载。</p>
                {[
                  ["摄像头", "FaceTime HD Camera"],
                  ["话筒", "MacBook Pro 麦克风"],
                  ["显示器", "内建显示器"],
                  ["系统声音", "默认输出设备"],
                ].map(([name, value]) => (
                  <label key={name}>
                    {name}
                    <select
                      disabled={!ready}
                      value={s.config?.[name] || value}
                      onChange={(e) =>
                        act("configure", { field: name, value: e.target.value })
                      }
                    >
                      <option>{value}</option>
                      <option>外接设备（模拟）</option>
                    </select>
                  </label>
                ))}
                <label>
                  输出目录
                  <input
                    disabled={!ready}
                    value={s.config?.输出目录 || "影片 / 庄Sir采访 / 今日采访"}
                    onChange={(e) =>
                      act("configure", {
                        field: "输出目录",
                        value: e.target.value,
                      })
                    }
                  />
                </label>
                <Meter type="camera" active />
                <Meter type="desktop" active />
                <button disabled={!ready} onClick={() => act("trial")}>
                  {s.phase === "trial"
                    ? "试录中，请说话并播放声音…"
                    : "试录 10 秒"}
                </button>
                {s.trialDone && (
                  <p role="status">
                    模拟试录完成，两路检查通过。正式版本需回放检查。
                  </p>
                )}
                <button className="primary" onClick={() => setExpanded(false)}>
                  准备完成 · 收起小窗
                </button>
              </section>
            )}
            <div className="guest-status">
              {!s.connected && <p>导演连接已断开，本地仍可操作。</p>}
              {statusPanel}
            </div>
          </div>
          {toolbar}
        </>
      ) : (
        <>
          <header className="topbar">
            <a className="brand" href="/">
              庄Sir <span>线上采访助手</span>
            </a>
            <div className="presence">
              <Users size={18} />
              在线 {people} 人 · 共享控制
            </div>
            <span className="no-login">固定网址 · 无需登录</span>
            <strong className="session-title">深度对谈 · 林老师</strong>
            <button
              className="guest-link"
              onClick={() => window.open("?view=guest", "_blank")}
            >
              嘉宾小窗 <ArrowsOut size={16} />
            </button>
          </header>
          {toolbar}
          {!s.connected && s.phase !== "closed" && (
            <div className="alert" role="alert">
              <WifiSlash />
              连接中断，当前状态待确认；嘉宾本地录制继续。恢复网络后同步。
              <button onClick={() => act("network", { remote: false })}>
                恢复网络
              </button>
            </div>
          )}
          {statusPanel}
          {tab === "control" ? (
            <main>
              <div className="monitors">
                {["desktop", "camera"].map((t) => (
                  <section className={`monitor ${t}`} key={t}>
                    <header>
                      <span>
                        {t === "desktop" ? <Monitor /> : <VideoCamera />}
                        {t === "desktop" ? "屏幕＋系统声音" : "摄像头＋话筒"}
                      </span>
                      <small>
                        {!alive
                          ? "预览已关闭"
                          : !s.connected || now - (s.previewAt || now) > 10000
                            ? "画面已过期 · 请检查画面"
                            : "静帧 · " +
                              Math.max(
                                0,
                                Math.floor((now - (s.previewAt || now)) / 1000),
                              ) +
                              (s.phase === "recording" ? "秒前 / 每5秒更新" : "秒前 / 按需检查")}
                      </small>
                    </header>
                    <div className="preview">
                      <img
                        src={asset(t)}
                        alt={
                          t === "camera"
                            ? "模拟嘉宾摄像头静帧"
                            : "模拟桌面演示静帧"
                        }
                      />
                      {(!s.tracks[t] || !alive) && (
                        <div className="preview-overlay">
                          {!alive ? "采集已关闭" : "未选择此机位"}
                        </div>
                      )}
                      {ready && (
                        <span className="preview-tag">预览中，未录制</span>
                      )}
                    </div>
                    <Meter
                      type={t}
                      active={alive && s.tracks[t] && s.connected}
                    />
                    {ready && (
                      <label className="track-choice">
                        <input
                          type="checkbox"
                          checked={s.tracks[t]}
                          disabled={remoteBlocked}
                          onChange={() => act("tracks", { track: t })}
                        />
                        录制此机位 <small>1920×1080 · 30 fps</small>
                      </label>
                    )}
                  </section>
                ))}
              </div>
              <section className="health">
                <div className="timer">
                  <div>
                    <span
                      className={
                        s.phase === "recording" ? "record-dot" : "ready-dot"
                      }
                    ></span>
                    {!s.connected && alive ? "状态待确认" : labels[s.phase]}
                  </div>
                  <time>{clock(elapsed)}</time>
                </div>
                {["desktop", "camera"].map((t) => (
                  <div className="track-health" key={t}>
                    {t === "desktop" ? (
                      <Monitor size={28} />
                    ) : (
                      <VideoCamera size={28} />
                    )}
                    <div>
                      <strong>
                        {t === "desktop" ? "屏幕＋系统声音" : "摄像头＋话筒"}
                      </strong>
                      <span className="health-label">
                        {!s.tracks[t]
                          ? "未选择"
                          : s.phase === "recording"
                            ? s.connected
                              ? "持续写入"
                              : "最后确认：录制中"
                            : labels[s.phase]}
                      </span>
                      <small>
                        已写入{" "}
                        {s.tracks[t]
                          ? (
                              elapsed * (t === "desktop" ? 0.0012 : 0.0015)
                            ).toFixed(2)
                          : "0.00"}{" "}
                        GB
                      </small>
                    </div>
                  </div>
                ))}
                <div className="disk">
                  <HardDrives size={27} />
                  <div>
                    <strong>磁盘剩余空间</strong>
                    <b>
                      148 <small>GB</small>
                    </b>
                    <small>可用空间 · 模拟值</small>
                  </div>
                </div>
              </section>
              <footer className="actions">
                <div className="activity">
                  <strong>
                    Take {String(s.takes.length + 1).padStart(2, "0")}
                  </strong>
                  <small>{s.lastAction}</small>
                </div>
                {primary}
                <button
                  disabled={remoteBlocked || !alive}
                  onClick={() => {
                    act("inspect");
                    setNotice("两路模拟静帧已更新");
                  }}
                >
                  <ImageIcon />
                  检查画面
                </button>
                <button
                  disabled={!s.takes.length || s.endRequested}
                  onClick={() => {
                    setTab("materials");
                    act("sheet");
                    setPage(0);
                  }}
                >
                  <FolderOpen />
                  素材检查
                </button>
                <div className="end-action">
                  <button
                    className="danger"
                    disabled={remoteBlocked || !alive}
                    onClick={end}
                  >
                    <Trash />
                    结束任务
                  </button>
                  <small>保存素材后卸载嘉宾端</small>
                </div>
              </footer>
              <p className="privacy">
                素材保留在嘉宾电脑 · 预览为模拟静帧，不是实时视频
              </p>
            </main>
          ) : (
            <main className="materials">
              <header>
                <button onClick={() => setTab("control")}>
                  <ArrowLeft />
                  返回控制台
                </button>
                <h1>素材检查</h1>
                <span>已保存在嘉宾电脑，尚未交付</span>
              </header>
              <div className="material-filters">
                <label>
                  素材
                  <select
                    value={selectedTake || s.takes.at(-1)?.id}
                    onChange={(e) => {
                      setSelectedTake(Number(e.target.value));
                      setPage(0);
                    }}
                  >
                    {s.takes.map((t) => (
                      <option key={t.id} value={t.id}>
                        Take {t.id} · {clock(t.duration)}
                      </option>
                    ))}
                  </select>
                </label>
                {["desktop", "camera"].map((t) => (
                  <button
                    key={t}
                    className={track === t ? "selected" : ""}
                    onClick={() => {
                      setTrack(t);
                      setPage(0);
                    }}
                  >
                    {t === "camera" ? "嘉宾机位" : "桌面机位"}
                  </button>
                ))}
                <button
                  onClick={() =>
                    setNotice("模拟：已请求嘉宾打开素材目录；不访问本机文件")
                  }
                >
                  请求嘉宾打开素材目录
                </button>
              </div>
              {(() => {
                const take =
                  s.takes.find((t) => t.id === selectedTake) || s.takes.at(-1);
                if (!take) return <p>暂无素材</p>;
                const times = frameTimes(take.duration);
                return take.tracks[track] ? (
                  <>
                    <p>模拟抽帧 · 每30秒＋首尾帧 · H.264 / 1080p / 音轨存在</p>
                    <div className="frame-grid">
                      {times.slice(page * 20, page * 20 + 20).map((time) => (
                        <button
                          key={time}
                          onClick={() => setZoom({ track, time })}
                        >
                          <img
                            src={asset(track)}
                            alt={`${clock(time)} 的模拟素材帧`}
                          />
                          <time>{clock(time)}</time>
                        </button>
                      ))}
                    </div>
                    <div className="pagination">
                      <button
                        disabled={page === 0}
                        onClick={() => setPage(page - 1)}
                      >
                        上一页
                      </button>
                      <span>
                        {page + 1} / {Math.ceil(times.length / 20)} 页 ·{" "}
                        {times.length} 帧
                      </span>
                      <button
                        disabled={(page + 1) * 20 >= times.length}
                        onClick={() => setPage(page + 1)}
                      >
                        下一页
                      </button>
                    </div>
                    <p>
                      此原型重复使用示例图片。正式产品必须从落盘视频解码，宫格无法确认声音质量。
                    </p>
                  </>
                ) : (
                  <p className="empty">这条 Take 没有录制该机位。</p>
                );
              })()}
            </main>
          )}
        </>
      )}
      {notice && (
        <div className="toast" role="status">
          {notice}
        </div>
      )}
      {modal === "end" && (
        <Modal title="结束本次采访？" onClose={() => setModal(null)}>
          <p>将停止采集并保存素材，撤销远程控制，清理并卸载嘉宾客户端。</p>
          <p>
            <strong>已录视频和恢复材料会保留。</strong>
          </p>
          <p className="muted">当前为模拟流程，不会删除文件或卸载任何程序。</p>
          <div className="modal-actions">
            <button onClick={() => setModal(null)}>返回</button>
            <button
              className="primary red"
              onClick={() => {
                setModal(null);
                act("end");
              }}
            >
              结束并卸载（模拟）
            </button>
          </div>
        </Modal>
      )}
      {modal === "reset" && (
        <Modal title="重置模拟任务？" onClose={() => setModal(null)}>
          <p>
            会清空本浏览器所有演示页面共享的模拟 Take 和状态，不影响真实文件。
          </p>
          <div className="modal-actions">
            <button onClick={() => setModal(null)}>返回</button>
            <button
              className="primary"
              onClick={() => {
                act("reset", { remote: false });
                setModal(null);
                setTab("control");
                setExpanded(false);
              }}
            >
              重置
            </button>
          </div>
        </Modal>
      )}
      {zoom && (
        <Modal
          title={`素材帧 · ${clock(zoom.time)}`}
          onClose={() => setZoom(null)}
        >
          <img
            className="zoom-image"
            src={asset(zoom.track)}
            alt={`${clock(zoom.time)}模拟帧`}
          />
        </Modal>
      )}
    </div>
  );
}
