# Tham chiếu before/after — apply preset / film look

Ngày: 2026-11-10. Nguồn: user hỏi lúc 13:41 ngày 10/11 "tìm giúp tôi 1 page hoặc kênh về apply preset/film look có before/after".
Chat chính lúc 13:41 đã gợi ý nhanh 2 cái đầu tiên (Austin Rupp, Linus Bergman).
File này giữ lại 2 cái đó + thêm 4 nguồn đã kiểm chứng link/post, và map từng nguồn với preset đang tune — để designer xem hướng màu, không phải để copy LUT hay lấy làm chuẩn đo.

## Quy tắc dùng file này (đọc trước)

- Chỉ xem **hướng màu** (warm/muted, grain, highlight/shadow). Không lấy before/after của page bán preset làm chuẩn đo LUT của mình — "before" thường bị làm tối/flat hơn thực tế để "after" ấn tượng hơn.
- Chuẩn đo vẫn là spec `spec-danh-gia-lut-va-tu-hieu-chuan-2026-11-10.md`: 5 fixture + 20 ảnh test, 8 metric (clip, da, màu nhớ, shadow…).
- Không ship LUT/preset từ các page này, không copy tên trademark (Portra, Velvia, Kodachrome, Fujifilm…) vào UI — xem `kiem-tra-ten-hien-thi-apple-review-2026-11-10.md` (đã phát hiện "Fuji Soft 400" vi phạm).

## 1. Đã gợi ý trong chat — giữ lại

### 1.1 Austin Rupp — @austinjrupp (Instagram)
- Format: carousel before/after cho preset pack "CineHue", split-screen before (tối, flat) vs after (sáng, ấm, film-like, có grain), chụp trên Fujifilm X100VI.
- Post mẫu đã kiểm chứng trong social index: https://www.instagram.com/p/DfR9OealFbL/
- Có post bóc tách setting Lightroom thật (Exposure +0.85, Contrast −19, Temp 5500K, tone curve, grain 24) — xem để hiểu preset được "nấu" thế nào.
- Dùng cho: hướng chung warm + grain; cách trình bày before/after dạng carousel 10–12 slide.
- Lưu ý: page bán preset — before thường bị dìm.

### 1.2 Linus Bergman — @liinusbergman (Instagram)
- Format: reel before/after preset Portra 800 trên 4 cảnh tuyết, biển, hồ núi ở Na Uy.
- Trạng thái kiểm chứng: **chưa kiểm chứng độc lập trong đợt này** (tìm trong social index ngày 10/11 không trả về post của tài khoản này). Mở link trong chat chính để xem trực tiếp trước khi đưa vào brief designer.
- Dùng cho: Portra trên cảnh lạnh/tuyết — đối chiếu với `portra-160.json` (da + highlight ấm trên nền lạnh).

## 2. Thêm — đã kiểm chứng post/link ngày 10/11

### 2.1 Oktavia Erna — @oktaviaaarn (Instagram, 110K followers theo social index)
- Post: https://www.instagram.com/p/DE9-4JnyGFN/ — 2025-01-18, carousel "Analog Film" bằng Lightroom Mobile.
- Before/after: slide 2, side-by-side; các slide sau bóc toàn bộ setting: Exposure +0.10, Contrast +22, Highlights +50, Shadows +55, tone curve RGB, HSL từng màu, split-toning, Vignette −22, Grain +39 (size 52, roughness 50).
- Dùng cho: **mẫu tốt nhất để designer học cách trình bày setting** — preset nào cũng nên có 1 slide before/after + 1 slide setting như vậy. Map: `superia-400.json`, `cpm35.json` (warm, desaturated, grain rõ).

### 2.2 Hogwarts Preset — @hogwartspreset (Instagram, 20K followers)
- Post: https://www.instagram.com/p/DXWJKFZmIfc/ — 2026-04-20, carousel 9 slide "How to create a AESTHETIC FILM".
- Before/after: slide áp chót; setting đầy đủ: Exposure −0.15, Contrast −30, Highlights −38, Shadows +61, Whites −63, Blacks +75, Temp +14, Clarity −30, Dehaze +28, Grain 20. Có disclaimer "kết quả phụ thuộc file RAW của bạn".
- Dùng cho: hướng muted/warm, lift shadow + crush white — đối chiếu `fuji-400h.json` (sau khi đổi tên, xem file Apple Review) và `grd-r.json`. Disclaimer về RAW là câu nên copy vào brief tune: cùng preset, khác file gốc thì khác kết quả.

### 2.3 Jamie Windsor (YouTube) — Kodachrome bằng Lightroom
- Video: https://www.youtube.com/watch?v=76tBq454nFc — "Getting the KODACHROME look using LIGHTROOM with these presets".
- Pack 15 preset Kodachrome, mô phỏng theo phong cách Steve McCurry / Ernst Haas / Saul Leiter; có cả Portra pack: https://jamiewindsor.com/portra
- Dùng cho: **film-stock cụ thể nhất** trong danh sách — map trực tiếp `kodachrome-64.json` (đỏ/magenta giàu, contrast cao). Xem cách ông tách "look" thành nhiều biến thể theo nhiếp ảnh gia, thay vì 1 preset duy nhất.

### 2.4 Fstoppers / Max Kent (YouTube + bài viết) — tự build preset film từ đầu
- Bài + video: https://fstoppers.com/education/how-make-digital-photos-look-film-lightroom-902358 — 2026-05-14, "Make Digital Photos Look Like Film".
- Nội dung: build preset mô phỏng Kodak Gold 200 / ColorPlus từ tone panel (lift highlight nhẹ, lift shadow/black, warm, giảm clarity/dehaze, grain) — rồi **test cùng preset trên 3 ảnh khác nhau (landscape, evening, portrait)**, mỗi ảnh tweak nhỏ ở temperature/HSL.
- Lưu ý kỹ thuật đáng giá: grain ở preview Lightroom khác grain sau export — xem trước khi chốt grain cho preset.
- Dùng cho: **phương pháp tune, không phải look** — đúng tinh thần spec đánh giá LUT §2 (scorecard LUT × scene) và brief tune 7 preset skeleton. Map chung cho cả 9 preset, đặc biệt `palm-springs.json` / `social-pop.json` (cần test đa scene trước khi khóa).

### 2.5 Presetpro — Portra 400, before/after theo từng mức độ
- Trang: https://www.presetpro.com/kodak-portra-400-lightroom-presets/?amp — "Kodak Portra 400 Lightroom Presets & Profiles (Before & After)", cập nhật 2026-07-24.
- Điểm hay: 1 look có 9 biến thể (base, +, ++, +++, ++++, film, cool, warm, boost) + profile riêng có Amount slider để chỉnh độ mạnh — "after" là 1 click preset, không grade tay thêm.
- Dùng cho: ý tưởng **intensity theo mức** — khớp spec tự hiệu chuẩn (intensity theo scene 30–100%). Map: `portra-160.json`, `superia-400.json`. Không copy tên "Portra 400" vào UI.

### 2.6 Picfair / Focus — free preset + cách recreate từng stock
- Bài: https://focus.picfair.com/articles/get-the-classic-look-of-kodachrome-velvia-tri-x-and-more-with-free-presets
- Nội dung: Kodachrome (boost contrast, HSL đỏ/magenta), Tri-X (B&W), Portra (S-curve nhẹ, lift luminance đỏ/cam cho da) — kèm preset Lightroom free để thử.
- Dùng cho: checklist nhanh "đặc trưng của từng stock là gì" khi designer tune `kodachrome-64.json`, `portra-160.json`, và B&W trong nhóm clean/B&W. Chỉ dùng để tham khảo hướng, không ship preset free này.

## Map nhanh: nguồn → preset đang tune

| Preset (presets-drop-2026/) | Nguồn đối chiếu chính |
|---|---|
| kodachrome-64.json | Jamie Windsor (§2.3), Picfair (§2.6) |
| portra-160.json | Presetpro (§2.5), Linus Bergman (§1.2, chưa kiểm chứng), Picfair (§2.6) |
| superia-400.json, cpm35.json | Oktavia Erna (§2.1) |
| fuji-400h.json, grd-r.json | Hogwarts Preset (§2.2) |
| palm-springs.json, social-pop.json | Fstoppers / Max Kent (§2.4) — test đa scene |
| cinestill-800t.json | Fstoppers §2.4 có nhắc halation (DxO Nik Collection) — xem để hiểu halation, không copy preset |

## Việc tiếp theo (không gấp)

1. User/designer mở 2–3 nguồn trên, chọn 1–2 hướng màu ưng nhất cho từng preset.
2. Designer tune theo `brief-tune-7-preset-skeleton-2026-11-07.md`, chốt before/after trên 5 fixture — không dùng before/after của page bán preset để duyệt.
3. Nếu muốn mở rộng: tìm thêm kênh TikTok/Reels cùng format (chưa làm trong file này — Instagram + YouTube đã đủ cho vòng tune hiện tại).
