// BxAudio: 曲とノーツ音を 1 本の音の流れの中で、サンプル単位で合わせて鳴らすミキサー。説明は include/bxaudio.h
//
// スレッドの約束:
//   ・bx_render ............ オーディオのスレッドだけ。ロックは try_lock だけ (取れなければ、そのブロックは無音)
//   ・bx_music_write など ... デコードのスレッドだけ (リングバッファの書き手は 1 つ)
//   ・それ以外 ............. メインのスレッドだけ (コマンドの書き手は 1 つ)
//   ・bx_reset / bx_set_sound は mutex を取って、オーディオのスレッドと同時に触らないようにする
//     (bx_reset はデコードのスレッドが止まっている間に呼ぶこと)

#include "bxaudio.h"

#include <atomic>
#include <mutex>
#include <vector>
#include <cstring>
#include <cmath>
#if defined(__APPLE__)
#include <mach/mach_time.h>
static inline uint64_t bxNowHost() { return mach_absolute_time(); }
#else
#include <time.h>
static inline uint64_t bxNowHost() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
#endif

namespace {

constexpr int kMaxSounds = 16;
constexpr int kMaxVoices = 64;
constexpr int kMaxEvents = 8192;
constexpr int kCmdCap = 4096;           // 2 の累乗

struct Sound {
    std::vector<float> l, r;
    int32_t frames = 0;
};

struct Voice {
    const Sound *s = nullptr;
    int32_t pos = 0;                    // 次に鳴らす、音の中のフレーム
    int32_t delay = 0;                  // このブロックで、鳴り始めるまでの無音のフレーム
    float gain = 1.f;
};

struct Event {
    int64_t frame;
    int32_t id;
    float gain;
};

enum CmdType : int32_t { kSchedule, kPlayNow, kCancelFrom, kLoop, kStart, kStop };

struct Cmd {
    int32_t type;
    int32_t id;
    int64_t frame;
    float gain;
};

}  // namespace

struct BxMixer {
    double sampleRate;

    // 曲のリングバッファ (書き手 = デコード、読み手 = 出力)
    int32_t ringCap;                    // 2 の累乗
    std::vector<float> ringL, ringR;
    std::atomic<int64_t> wIdx{0};
    std::atomic<int64_t> rIdx{0};
    std::atomic<bool> eof{false};

    // コマンド (書き手 = メイン、読み手 = 出力)
    Cmd cmds[kCmdCap];
    std::atomic<int64_t> cW{0};
    std::atomic<int64_t> cR{0};

    std::mutex mtx;                     // reset / set_sound と出力を分ける

    // ここから下は、出力のスレッド (と mutex を持った reset / set_sound) だけが触る
    Sound *sounds[kMaxSounds] = {};
    Voice voices[kMaxVoices];
    int32_t voiceCount = 0;
    Event events[kMaxEvents];
    int32_t eventCount = 0;
    bool playing = false;
    int64_t framePos = 0;               // タイムラインの、次に出力するフレーム
    int64_t lead = 0;                   // 曲の頭より前の無音のフレーム数
    int32_t loopId = -1;
    float loopTarget = 0.f;
    float loopGain = 0.f;
    int32_t loopPos = 0;

    std::atomic<float> musicGain{1.f};
    std::atomic<float> seGain{1.f};
    std::atomic<bool> playingFlag{false};
    std::atomic<int64_t> underruns{0};

    // 時計 (シーケンスロック。書き手 = 出力)
    std::atomic<uint32_t> clockSeq{0};
    std::atomic<int64_t> clockFrame{0};
    std::atomic<uint64_t> clockHost{0};
    std::atomic<int32_t> clockValid{0};

    // 作業用 (出力のスレッドだけ)
    std::vector<float> seL, seR;
};

namespace {

void pushCmd(BxMixer *m, const Cmd &c) {
    int64_t w = m->cW.load(std::memory_order_relaxed);
    int64_t r = m->cR.load(std::memory_order_acquire);
    if (w - r >= kCmdCap) return;       // あふれたら捨てる (通常は起こらない)
    m->cmds[w & (kCmdCap - 1)] = c;
    m->cW.store(w + 1, std::memory_order_release);
}

void startVoice(BxMixer *m, int32_t id, float gain, int32_t delay) {
    if (id < 0 || id >= kMaxSounds) return;
    const Sound *s = m->sounds[id];
    if (!s || s->frames <= 0) return;
    Voice v;
    v.s = s;
    v.pos = 0;
    v.delay = delay;
    v.gain = gain;
    if (m->voiceCount < kMaxVoices) {
        m->voices[m->voiceCount++] = v;
        return;
    }
    // いっぱいなら、いちばん長く鳴っているものと入れ替える
    int32_t best = 0;
    for (int32_t i = 1; i < m->voiceCount; i++) {
        if (m->voices[i].pos > m->voices[best].pos) best = i;
    }
    m->voices[best] = v;
}

void drainCmds(BxMixer *m) {
    int64_t r = m->cR.load(std::memory_order_relaxed);
    int64_t w = m->cW.load(std::memory_order_acquire);
    while (r < w) {
        const Cmd c = m->cmds[r & (kCmdCap - 1)];
        r++;
        switch (c.type) {
        case kSchedule:
            if (m->eventCount < kMaxEvents) m->events[m->eventCount++] = Event{c.frame, c.id, c.gain};
            break;
        case kPlayNow:
            startVoice(m, c.id, c.gain, 0);
            break;
        case kCancelFrom: {
            int32_t k = 0;
            for (int32_t i = 0; i < m->eventCount; i++) {
                if (m->events[i].frame < c.frame) m->events[k++] = m->events[i];
            }
            m->eventCount = k;
            break;
        }
        case kLoop:
            if (c.id != m->loopId) {
                m->loopId = c.id;
                m->loopPos = 0;
                m->loopGain = 0.f;
            }
            m->loopTarget = c.gain;
            break;
        case kStart:
            m->playing = true;
            m->clockValid.store(0, std::memory_order_release);
            break;
        case kStop:
            m->playing = false;
            m->eventCount = 0;
            m->loopTarget = 0.f;
            break;
        }
    }
    m->cR.store(r, std::memory_order_release);
}

void writeClock(BxMixer *m, int64_t frame, uint64_t host) {
    uint32_t s = m->clockSeq.load(std::memory_order_relaxed);
    m->clockSeq.store(s + 1, std::memory_order_release);      // 奇数 = 書いている途中
    std::atomic_thread_fence(std::memory_order_release);
    m->clockFrame.store(frame, std::memory_order_relaxed);
    m->clockHost.store(host, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    m->clockSeq.store(s + 2, std::memory_order_release);
    m->clockValid.store(1, std::memory_order_release);
}

}  // namespace

extern "C" {

BxMixer *bx_new(double sampleRate, int32_t ringFrames) {
    BxMixer *m = new BxMixer();
    m->sampleRate = sampleRate > 0 ? sampleRate : 44100.0;
    int32_t cap = 1024;
    while (cap < ringFrames && cap < (1 << 22)) cap <<= 1;
    m->ringCap = cap;
    m->ringL.assign(cap, 0.f);
    m->ringR.assign(cap, 0.f);
    m->seL.assign(8192, 0.f);
    m->seR.assign(8192, 0.f);
    return m;
}

void bx_free(BxMixer *m) {
    if (!m) return;
    for (int i = 0; i < kMaxSounds; i++) delete m->sounds[i];
    delete m;
}

void bx_set_sound(BxMixer *m, int32_t id, const float *l, const float *r, int32_t frames) {
    if (!m || id < 0 || id >= kMaxSounds || frames < 0) return;
    Sound *s = new Sound();
    s->frames = frames;
    s->l.assign(l, l + frames);
    s->r.assign(r ? r : l, (r ? r : l) + frames);
    Sound *old = nullptr;
    {
        std::lock_guard<std::mutex> g(m->mtx);
        old = m->sounds[id];
        m->sounds[id] = s;
        // 古い音を鳴らしている途中の声は止める (消す音を読まないように)
        int32_t k = 0;
        for (int32_t i = 0; i < m->voiceCount; i++) {
            if (m->voices[i].s != old) m->voices[k++] = m->voices[i];
        }
        m->voiceCount = k;
    }
    delete old;
}

int32_t bx_music_space(BxMixer *m) {
    int64_t w = m->wIdx.load(std::memory_order_relaxed);
    int64_t r = m->rIdx.load(std::memory_order_acquire);
    return (int32_t)(m->ringCap - (w - r));
}

int32_t bx_music_buffered(BxMixer *m) {
    int64_t w = m->wIdx.load(std::memory_order_acquire);
    int64_t r = m->rIdx.load(std::memory_order_acquire);
    return (int32_t)(w - r);
}

int32_t bx_music_write(BxMixer *m, const float *l, const float *r, int32_t frames) {
    int64_t w = m->wIdx.load(std::memory_order_relaxed);
    int64_t rd = m->rIdx.load(std::memory_order_acquire);
    int32_t space = (int32_t)(m->ringCap - (w - rd));
    int32_t n = frames < space ? frames : space;
    if (n <= 0) return 0;
    int32_t mask = m->ringCap - 1;
    int32_t start = (int32_t)(w & mask);
    int32_t first = n < (m->ringCap - start) ? n : (m->ringCap - start);
    std::memcpy(&m->ringL[start], l, first * sizeof(float));
    std::memcpy(&m->ringR[start], r ? r : l, first * sizeof(float));
    if (n > first) {
        std::memcpy(&m->ringL[0], l + first, (n - first) * sizeof(float));
        std::memcpy(&m->ringR[0], (r ? r : l) + first, (n - first) * sizeof(float));
    }
    m->wIdx.store(w + n, std::memory_order_release);
    return n;
}

void bx_music_eof(BxMixer *m) { m->eof.store(true, std::memory_order_release); }

void bx_reset(BxMixer *m, int64_t leadFrames) {
    std::lock_guard<std::mutex> g(m->mtx);
    m->cR.store(m->cW.load(std::memory_order_acquire), std::memory_order_release);   // 未処理のコマンドは捨てる
    m->playing = false;
    m->playingFlag.store(false, std::memory_order_release);
    m->eventCount = 0;
    m->framePos = 0;
    m->lead = leadFrames > 0 ? leadFrames : 0;
    m->loopTarget = 0.f;
    m->wIdx.store(0, std::memory_order_release);
    m->rIdx.store(0, std::memory_order_release);
    m->eof.store(false, std::memory_order_release);
    m->underruns.store(0, std::memory_order_release);
    m->clockValid.store(0, std::memory_order_release);
}

void bx_start(BxMixer *m) {
    m->playingFlag.store(true, std::memory_order_release);
    m->clockValid.store(0, std::memory_order_release);
    pushCmd(m, Cmd{kStart, 0, 0, 0.f});
}

void bx_stop(BxMixer *m) {
    m->playingFlag.store(false, std::memory_order_release);
    pushCmd(m, Cmd{kStop, 0, 0, 0.f});
}

int32_t bx_is_playing(BxMixer *m) { return m->playingFlag.load(std::memory_order_acquire) ? 1 : 0; }

void bx_schedule(BxMixer *m, int64_t frame, int32_t id, float gain) { pushCmd(m, Cmd{kSchedule, id, frame, gain}); }
void bx_play_now(BxMixer *m, int32_t id, float gain) { pushCmd(m, Cmd{kPlayNow, id, 0, gain}); }
void bx_cancel_from(BxMixer *m, int64_t frame) { pushCmd(m, Cmd{kCancelFrom, 0, frame, 0.f}); }
void bx_set_loop(BxMixer *m, int32_t id, float gain) { pushCmd(m, Cmd{kLoop, id, 0, gain}); }

void bx_set_music_gain(BxMixer *m, float g) { m->musicGain.store(g, std::memory_order_relaxed); }
void bx_set_se_gain(BxMixer *m, float g) { m->seGain.store(g, std::memory_order_relaxed); }

int32_t bx_clock(BxMixer *m, int64_t *frame, uint64_t *hostTime) {
    if (!m->clockValid.load(std::memory_order_acquire)) return 0;
    for (int tries = 0; tries < 64; tries++) {
        uint32_t s1 = m->clockSeq.load(std::memory_order_acquire);
        if (s1 & 1) continue;
        std::atomic_thread_fence(std::memory_order_acquire);
        int64_t f = m->clockFrame.load(std::memory_order_relaxed);
        uint64_t h = m->clockHost.load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        uint32_t s2 = m->clockSeq.load(std::memory_order_acquire);
        if (s1 == s2) {
            *frame = f;
            *hostTime = h;
            return 1;
        }
    }
    return 0;
}

int64_t bx_underruns(BxMixer *m) { return m->underruns.load(std::memory_order_relaxed); }

void bx_render(BxMixer *m, uint64_t hostTime, int32_t frames, float *l, float *r) {
    if (frames <= 0) return;
    std::memset(l, 0, frames * sizeof(float));
    std::memset(r, 0, frames * sizeof(float));
    if (!m->mtx.try_lock()) return;     // reset / set_sound の最中は、このブロックだけ無音

    if (hostTime == 0) hostTime = bxNowHost();
    drainCmds(m);

    if ((int32_t)m->seL.size() < frames) {
        // 普通は起こらない (出力のブロックは 8192 フレームより小さい)。起きたら、入るぶんだけ処理する
        frames = (int32_t)m->seL.size();
    }
    float *sl = m->seL.data();
    float *sr = m->seR.data();
    std::memset(sl, 0, frames * sizeof(float));
    std::memset(sr, 0, frames * sizeof(float));

    if (m->playing) {
        const int64_t f0 = m->framePos;
        const int64_t f1 = f0 + frames;

        // --- 曲 ---
        int32_t silent = 0;
        if (f0 < m->lead) {
            int64_t s = m->lead - f0;
            silent = (int32_t)(s < frames ? s : frames);
        }
        int32_t need = frames - silent;
        if (need > 0) {
            int64_t w = m->wIdx.load(std::memory_order_acquire);
            int64_t rd = m->rIdx.load(std::memory_order_relaxed);
            int32_t avail = (int32_t)(w - rd);
            int32_t n = need < avail ? need : avail;
            const float mg = m->musicGain.load(std::memory_order_relaxed);
            int32_t mask = m->ringCap - 1;
            for (int32_t i = 0; i < n; i++) {
                int32_t idx = (int32_t)((rd + i) & mask);
                l[silent + i] = m->ringL[idx] * mg;
                r[silent + i] = m->ringR[idx] * mg;
            }
            m->rIdx.store(rd + n, std::memory_order_release);
            if (n < need && !m->eof.load(std::memory_order_acquire)) {
                m->underruns.fetch_add(need - n, std::memory_order_relaxed);
            }
        }

        // --- 予約したノーツ音: このブロックに入るものを鳴らし始める (ブロックの中の位置まで合わせる) ---
        int32_t k = 0;
        for (int32_t i = 0; i < m->eventCount; i++) {
            const Event &e = m->events[i];
            if (e.frame < f1) {
                int64_t d = e.frame - f0;
                startVoice(m, e.id, e.gain, d > 0 ? (int32_t)d : 0);
            } else {
                m->events[k++] = e;
            }
        }
        m->eventCount = k;

        writeClock(m, f0, hostTime);
        m->framePos = f1;
    }

    // --- 効果音を混ぜる ---
    int32_t k = 0;
    for (int32_t vi = 0; vi < m->voiceCount; vi++) {
        Voice v = m->voices[vi];
        const Sound *s = v.s;
        int32_t i = v.delay;
        int32_t p = v.pos;
        while (i < frames && p < s->frames) {
            sl[i] += s->l[p] * v.gain;
            sr[i] += s->r[p] * v.gain;
            i++;
            p++;
        }
        v.pos = p;
        v.delay = 0;
        if (p < s->frames) m->voices[k++] = v;
    }
    m->voiceCount = k;

    // --- くり返しの音 (ホールドの「しゅ〜」)。大きさは 5ms かけて変える (プチ音が出ないように) ---
    if (m->loopId >= 0 && m->loopId < kMaxSounds) {
        const Sound *s = m->sounds[m->loopId];
        if (s && s->frames > 0 && (m->loopGain > 0.0001f || m->loopTarget > 0.0001f)) {
            const float step = (float)(1.0 / (0.005 * m->sampleRate));
            float g = m->loopGain;
            int32_t p = m->loopPos;
            for (int32_t i = 0; i < frames; i++) {
                if (g < m->loopTarget) { g += step; if (g > m->loopTarget) g = m->loopTarget; }
                else if (g > m->loopTarget) { g -= step; if (g < m->loopTarget) g = m->loopTarget; }
                if (p >= s->frames) p = 0;
                sl[i] += s->l[p] * g;
                sr[i] += s->r[p] * g;
                p++;
            }
            m->loopGain = g;
            m->loopPos = p;
        }
    }

    const float sg = m->seGain.load(std::memory_order_relaxed);
    for (int32_t i = 0; i < frames; i++) {
        l[i] += sl[i] * sg;
        r[i] += sr[i] * sg;
    }
    m->mtx.unlock();
}

}  // extern "C"
