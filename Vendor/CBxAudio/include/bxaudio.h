// BxAudio: 曲とノーツ音を「1 本の音の流れ」の中で、サンプル単位でぴったり合わせて鳴らすミキサー (C++ / C の窓口)。
//
// ・曲の PCM は、デコード用のスレッドが bx_music_write で「リングバッファ」に書き込む (1 書き手・1 読み手。ロックなし)
// ・ノーツ音は「タイムライン上のフレーム番号」で予約する (bx_schedule)。タイムライン = 再生を始めてから出力したフレーム数。
//   曲の音も同じタイムラインで流れるので、ノーツ音は曲のサンプルとぴったり同じ位置で鳴る (出力の遅れ・時計のずれに関係なく)
// ・出力 (bx_render) はオーディオのスレッドから呼ぶ。メモリの確保・ロック待ちをしない
// ・時計: bx_clock で「直近に出力したブロックの先頭のタイムラインのフレーム」と「そのブロックのホスト時刻 (mach_absolute_time)」が取れる
#ifndef BXAUDIO_H
#define BXAUDIO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BxMixer BxMixer;

/// sampleRate: 曲と同じ (出力もこのサンプリング周波数で作る)。ringFrames: 曲のリングバッファの大きさ (フレーム)
BxMixer *bx_new(double sampleRate, int32_t ringFrames);
void bx_free(BxMixer *m);

/// 効果音を登録する (id は 0〜15)。中身はコピーする。再生中に呼んでもよい (差し替えはオーディオのスレッドが安全に受け取る)
void bx_set_sound(BxMixer *m, int32_t id, const float *l, const float *r, int32_t frames);

// ---- 曲 (デコードのスレッドから) ----
/// リングバッファの空き (フレーム)
int32_t bx_music_space(BxMixer *m);
/// 書けたフレーム数を返す
int32_t bx_music_write(BxMixer *m, const float *l, const float *r, int32_t frames);
/// 曲の終わりまで書いた
void bx_music_eof(BxMixer *m);

// ---- 再生の制御 (メインのスレッドから。bx_reset はデコードのスレッドが止まっている間に呼ぶ) ----
/// 止めて、曲のリングバッファと予約を空にする。次の再生は、タイムラインの 0 から。
/// leadFrames: 曲の頭より前の無音のフレーム数 (曲が始まる前の位置から再生するとき)
void bx_reset(BxMixer *m, int64_t leadFrames);
/// 再生を始める (次に出力するブロックから)
void bx_start(BxMixer *m);
/// 止める (曲は止まる。今鳴っている効果音は鳴り終わるまで鳴らす)
void bx_stop(BxMixer *m);
int32_t bx_is_playing(BxMixer *m);

// ---- 効果音 (メインのスレッドから) ----
/// タイムラインのフレーム frame に効果音 id を鳴らす (すでに過ぎていたら、すぐ鳴らす)
void bx_schedule(BxMixer *m, int64_t frame, int32_t id, float gain);
/// すぐ鳴らす (次に出力するブロックの頭から)
void bx_play_now(BxMixer *m, int32_t id, float gain);
/// まだ鳴っていない予約のうち、frame 以降のものを捨てる
void bx_cancel_from(BxMixer *m, int64_t frame);
/// くり返し鳴らす音 (ホールドの「しゅ〜」)。gain 0 で止める。id < 0 で無し
void bx_set_loop(BxMixer *m, int32_t id, float gain);

void bx_set_music_gain(BxMixer *m, float g);
void bx_set_se_gain(BxMixer *m, float g);

// ---- 時計 ----
/// 直近のブロック: その先頭サンプルのタイムラインのフレーム、ホスト時刻 (mach_absolute_time の単位)。
/// まだ再生してから 1 回も出力していなければ 0 を返す
int32_t bx_clock(BxMixer *m, int64_t *frame, uint64_t *hostTime);
/// 曲の音が足りなかった (デコードが間に合わなかった) フレーム数の合計
int64_t bx_underruns(BxMixer *m);
/// リングバッファに入っている曲のフレーム数
int32_t bx_music_buffered(BxMixer *m);

// ---- 出力 (オーディオのスレッドから) ----
/// hostTime: このブロックの時刻 (0 なら今の時刻を使う)。l / r に frames フレームを書く
void bx_render(BxMixer *m, uint64_t hostTime, int32_t frames, float *l, float *r);

#ifdef __cplusplus
}
#endif

#endif
