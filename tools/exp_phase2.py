"""Phase 2 task 2.0 offline experiments (Python reference, Core ML models). LOCAL ONLY: reads user/stock face media from
tools/models/test and writes contact sheets there (gitignored). Never commit outputs.

  modec   : swap every Nth frame, in-between frames re-warp the last patch with the CURRENT frame's landmarks (Mode C)
            or paste it at its own stale M (Mode B), vs swapping every frame (reference). Metric: face-region PSNR.
  strength: 1 vs 2 swapper passes (+ alpha blend) on identity similarity and expression retention.
"""
import sys
from pathlib import Path
import cv2, numpy as np
sys.path.insert(0, str(Path(__file__).parent))
import reference_pipeline as rp

T = rp.TEST
b = rp.CML()
emap = np.fromfile(rp.ROOT / "emap.bin", "<f4").reshape(512, 512)


def source_identity(path):
    src = cv2.imread(str(path))
    _, k = rp.face(src, b)
    a112, _ = rp.align(src, k, 112)
    emb = b.embed(a112); emb = emb / np.linalg.norm(emb)
    lat = emb.reshape(1, -1) @ emap
    return emb, (lat / np.linalg.norm(lat)).astype(np.float32)


def swap_patch(frame, kps, latent):
    a128, M = rp.align(frame, kps, 128)
    pred = b.swap(a128, latent)
    fake = np.clip(255 * pred.transpose(0, 2, 3, 1)[0], 0, 255).astype(np.uint8)[:, :, ::-1].copy()
    return fake, a128, M


def face_box(M, H, W, pad=0):
    IM = cv2.invertAffineTransform(M)
    c = np.array([[0, 0], [128, 0], [128, 128], [0, 128]], np.float32) @ IM[:, :2].T + IM[:, 2]
    return (max(0, int(c[:, 0].min()) - pad), max(0, int(c[:, 1].min()) - pad),
            min(W, int(c[:, 0].max()) + pad), min(H, int(c[:, 1].max()) + pad))


def psnr(a, b_):
    mse = np.mean((a.astype(np.float32) - b_.astype(np.float32)) ** 2)
    return 99.0 if mse < 1e-9 else 10 * np.log10(255 ** 2 / mse)


def modec(clip, start, count, src_path, step=1):
    emb, lat = source_identity(src_path)
    cap = cv2.VideoCapture(str(clip)); cap.set(cv2.CAP_PROP_POS_FRAMES, start)
    frames, kpss, patches = [], [], []
    for _ in range(count):
        ok, f = cap.read()
        if not ok: break
        try:
            _, k = rp.face(f, b)
        except RuntimeError:
            continue
        frames.append(f); kpss.append(k)
        patches.append(swap_patch(f, k, lat))
    H, W = frames[0].shape[:2]
    ref = [rp.paste_back(f, p[0], p[1], p[2]) for f, p in zip(frames, patches)]
    print(f"{clip.name}: {len(frames)} frames with a face, {W}x{H}")
    rows = {}
    for N in (2, 3, 4, 6, 12):
        sc, sb, sraw = [], [], []
        for j, f in enumerate(frames):
            i = (j // N) * N
            if i == j: continue  # frame that was really swapped: exact, excluded so it does not inflate the stats
            fake_i, a_i, M_i = patches[i]
            M_j = patches[j][2]  # current frame's alignment (fresh detection every frame)
            x0, y0, x1, y1 = face_box(M_j, H, W)
            c = rp.paste_back(f, fake_i, a_i, M_j)     # Mode C: re-warp stale patch with current M
            bb = rp.paste_back(f, fake_i, a_i, M_i)    # Mode B: stale patch at its own stale M
            sc.append(psnr(c[y0:y1, x0:x1], ref[j][y0:y1, x0:x1]))
            sb.append(psnr(bb[y0:y1, x0:x1], ref[j][y0:y1, x0:x1]))
            sraw.append(psnr(f[y0:y1, x0:x1], ref[j][y0:y1, x0:x1]))
        rows[N] = (np.mean(sc), np.percentile(sc, 10), np.mean(sb), np.percentile(sb, 10), np.mean(sraw))
        print(f"  N={N:2d}  Mode C face PSNR vs every-frame swap (in-between frames only): mean {rows[N][0]:.1f} dB (p10 {rows[N][1]:.1f}) | "
              f"Mode B (stale M): mean {rows[N][2]:.1f} (p10 {rows[N][3]:.1f}) | unswapped raw: {rows[N][4]:.1f}")
    # contact sheet: worst-case frame for N=6
    N = 6; worst, wj = 999, 0
    for j, f in enumerate(frames):
        i = (j // N) * N
        x0, y0, x1, y1 = face_box(patches[j][2], H, W)
        s = psnr(rp.paste_back(f, patches[i][0], patches[i][1], patches[j][2])[y0:y1, x0:x1], ref[j][y0:y1, x0:x1])
        if s < worst: worst, wj = s, j
    j = wj; i = (j // N) * N
    x0, y0, x1, y1 = face_box(patches[j][2], H, W, pad=20)
    tiles = [frames[j], ref[j], rp.paste_back(frames[j], patches[i][0], patches[i][1], patches[j][2]),
             rp.paste_back(frames[j], patches[i][0], patches[i][1], patches[i][2])]
    sheet = np.hstack([cv2.resize(t[y0:y1, x0:x1], (300, 300)) for t in tiles])
    out = T / f"sheet_modec_{clip.stem}.png"; cv2.imwrite(str(out), sheet)
    print(f"  worst N=6 frame #{j} ({worst:.1f} dB); sheet [raw | every-frame swap | Mode C | Mode B] -> {out.name}")
    return rows


def crop112(fake128):
    return np.ascontiguousarray(fake128[0:112, 8:120])  # 128 template = 112 template shifted +8 in x


def strength(src_path, targets):
    emb, lat = source_identity(src_path)
    print("strength: ArcFace cos to SOURCE of the swapped face, and landmark drift vs the target (in inter-eye distances)")
    agg = {}
    sheet_rows = []
    for name, img in targets:
        try:
            _, k = rp.face(img, b)
        except RuntimeError:
            continue
        f1, a128, M = swap_patch(img, k, lat)
        # pass 2: feed pass-1 output back as the swapper target, same latent
        pred2 = b.swap(f1, lat)
        f2 = np.clip(255 * pred2.transpose(0, 2, 3, 1)[0], 0, 255).astype(np.uint8)[:, :, ::-1].copy()
        f3 = np.clip(255 * b.swap(f2, lat).transpose(0, 2, 3, 1)[0], 0, 255).astype(np.uint8)[:, :, ::-1].copy()
        variants = {"orig target": a128, "100 (1 pass)": f1,
                    "150 (blend 0.5)": (0.5 * f2 + 0.5 * f1).astype(np.uint8), "200 (2 pass)": f2, "300 (3 pass)": f3}
        iod = np.linalg.norm(k[0] - k[1])
        H, W = img.shape[:2]
        comps = {}
        for v, fk in variants.items():
            e = b.embed(crop112(fk)); e = e / np.linalg.norm(e)
            comp = rp.paste_back(img, fk, a128, M) if v != "orig target" else img
            comps[v] = comp
            try:
                _, k2 = rp.face(comp, b); drift = np.linalg.norm(k2 - k, axis=1).mean() / iod
            except RuntimeError:
                drift = float("nan")
            agg.setdefault(v, []).append((float(e @ emb), drift))
        x0, y0, x1, y1 = face_box(M, H, W, pad=20)
        sheet_rows.append(np.hstack([cv2.resize(c[y0:y1, x0:x1], (240, 240)) for c in comps.values()]))
    for v, vals in agg.items():
        a = np.array(vals)
        print(f"  {v:16s} id-cos-to-source {np.nanmean(a[:, 0]):.3f}   landmark drift {np.nanmean(a[:, 1]):.4f}  (n={len(a)})")
    out = T / "sheet_strength.png"; cv2.imwrite(str(out), np.vstack(sheet_rows))
    print("  sheet rows=targets, cols = orig | 100 | 150 | 200 | 300 ->", out.name)


if __name__ == "__main__":
    which = sys.argv[1]
    src = T / "source.jpeg"
    if which == "modec":
        for clip, start in ((T / "stock_2960.mp4", 100), (T / "stock_42323.mp4", 100)):
            modec(clip, start, 96, src)
    else:
        tg = [("test target", cv2.imread(str(T / "target.jpg")))]
        for clip in (T / "stock_2960.mp4", T / "stock_42323.mp4"):
            cap = cv2.VideoCapture(str(clip))
            for fi in (60, 150, 240):
                cap.set(cv2.CAP_PROP_POS_FRAMES, fi); ok, f = cap.read()
                if ok: tg.append((f"{clip.stem}#{fi}", f))
        strength(src, tg)
