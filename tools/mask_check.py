"""Check an analytic paste-back mask (distance to warped square, CDF-blurred) against insightface's erode+blur mask.
Local only; reads golden.npz + target image from tools/models/test (gitignored). Phase 1/2 Swift/Metal port this math."""
import math, sys
import cv2, numpy as np
from scipy.special import erf
sys.path.insert(0, '.')
import reference_pipeline as rp

T = rp.TEST
tgt = cv2.imread(str(T / 'target.jpg'))
g = np.load(T / 'golden.npz')
M = g['ort_M']; fake = g['ort_fake']; a = g['ort_a128']
H, W = tgt.shape[:2]


def analytic_mask(M, H, W, size=128):
    s = math.hypot(M[0, 0], M[1, 0])
    th = math.atan2(M[1, 0], M[0, 0])
    IM = cv2.invertAffineTransform(M)
    # bbox of warped square -> ms like insightface
    corners = np.array([[0, 0], [size, 0], [size, size], [0, size]], np.float32)
    wc = corners @ IM[:, :2].T + IM[:, 2]
    mw = wc[:, 0].max() - wc[:, 0].min(); mh = wc[:, 1].max() - wc[:, 1].min()
    ms = int(math.sqrt(mh * mw))
    k = max(ms // 10, 10); k2 = max(ms // 20, 5)
    sigma = 0.3 * ((2 * k2 + 1 - 1) * 0.5 - 1) + 0.8
    e = k / 2 * (abs(math.cos(th)) + abs(math.sin(th)))  # inward shift of axis-aligned box erosion
    ys, xs = np.mgrid[:H, :W].astype(np.float32)
    ax = M[0, 0] * xs + M[0, 1] * ys + M[0, 2]
    ay = M[1, 0] * xs + M[1, 1] * ys + M[1, 2]
    d = np.minimum(np.minimum(ax, size - ax), np.minimum(ay, size - ay)) / s  # px inside the square (image units)
    z = (d - e) / (sigma * math.sqrt(2))
    return 0.5 * (1 + erf(z))


def ref_mask(M):
    IM = cv2.invertAffineTransform(M)
    white = cv2.warpAffine(np.full((128, 128), 255, np.float32), IM, (W, H), borderValue=0.0)
    white[white > 20] = 255
    ys, xs = np.where(white == 255)
    ms = int(np.sqrt((ys.max() - ys.min()) * (xs.max() - xs.min())))
    k = max(ms // 10, 10)
    m = cv2.erode(white, np.ones((k, k), np.uint8))
    k = max(ms // 20, 5)
    return cv2.GaussianBlur(m, tuple(2 * i + 1 for i in (k, k)), 0) / 255


def blend(mask):
    IM = cv2.invertAffineTransform(M)
    bgr = cv2.warpAffine(fake, IM, (W, H), borderValue=0.0)
    m = mask[:, :, None]
    return (m * bgr + (1 - m) * tgt.astype(np.float32)).astype(np.uint8)


def variants():
    IM = cv2.invertAffineTransform(M)
    cx, cy = IM @ np.array([64, 64, 1.0])
    yield 'golden', M
    for deg in (15, 30, 45, -30):  # rotate the face about its centre
        R = cv2.getRotationMatrix2D((float(cx), float(cy)), deg, 1.0)
        Rh = np.vstack([R, [0, 0, 1]]); Mh = np.vstack([M, [0, 0, 1]])
        yield 'rot%+d' % deg, (Mh @ np.linalg.inv(Rh))[:2]
    A = np.array([[3.0, 0, 64 - 3 * 64], [0, 3.0, 64 - 3 * 64]])  # face 3x smaller in the image
    yield 'small/3', (np.vstack([A, [0, 0, 1]]) @ np.vstack([M, [0, 0, 1]]))[:2]
    for name, (dx, dy) in {'offframe-right': (W - 20 - cx, 0), 'offframe-top': (0, 10 - cy)}.items():
        T = np.array([[1, 0, dx], [0, 1, dy], [0, 0, 1.0]])
        yield name, (np.vstack([M, [0, 0, 1]]) @ np.linalg.inv(T))[:2]


for name, Mv in variants():
    Mg = M
    M = Mv
    try:
        rm, am = ref_mask(Mv), analytic_mask(Mv, H, W)
        r, an = blend(rm), blend(am)
        mse = float(np.mean((r.astype(np.float32) - an.astype(np.float32)) ** 2))
        print('%-15s mask mean diff %.4f max %.3f | blended PSNR %.2f dB' % (name, np.abs(rm - am).mean(), np.abs(rm - am).max(), 10 * np.log10(255 ** 2 / max(mse, 1e-9))))
    except Exception as ex:
        print(name, 'ERR', ex)
    M = Mg
