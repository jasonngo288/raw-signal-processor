# Đổi tên film stock — prefix RR (11/11/2026)

Nguồn: bảng giá shop gửi (35mm COLOR, giá VNĐ/cuộn 36 kiểu). 19 dòng trong
bảng → 21 stock (KodaColor 100/200 và Reto Prism 200/400 tách theo ISO).
Mục đích: tên hiển thị trong app không dùng trademark của hãng film, nhưng
vẫn giữ được "linh hồn" của từng stock để người dùng nhận ra khi chọn cuộn
và khi mở reveal.

## 1. Rule đặt tên (10 rule)

| # | Rule | Lý do |
|---|---|---|
| R1 | **Bỏ cả tên hãng lẫn tên dòng** trong UI: Kodak, Fuji/Fujifilm, Portra, Ektar, Gold, ColorPlus, Ultramax, Cinestill, Ektacolor, KodaColor, Reto/Retocolor, Proimage, YesStar. Chỉ giữ số ISO + từ mô tả cảm giác màu. | Tránh trademark (quy tắc đã chốt từ 07/11: display name không dùng tên hãng). |
| R2 | **Format cố định: `RR <từ mô tả> <ISO>`** — prefix `RR` + 1–2 từ mô tả + số ISO. Ví dụ: `RR Vàng 200`. | Nhận diện thương hiệu app, đọc nhanh, chọn theo ISO như chọn film thật. |
| R3 | Từ mô tả = **tiếng Việt, gợi cảm giác màu / hoàn cảnh** (Vàng, Ấm, Mát, Nắng, Đêm, Da Mềm…), không gợi tên hãng. | Người Việt đọc hiểu ngay; không dịch tên hãng sang tiếng Việt (vd không gọi "Sao" cho Star nếu đó là brand — xem R3a). |
| R3a | Ngoại lệ duy nhất: YesStar → `Sao Mai` / `Sao Hôm` (dịch nghĩa "ngôi sao" + buổi trong ngày). Đây là **từ chung trong tiếng Việt**, không phải tên hãng; nếu pháp lý muốn chắc chắn hơn thì đổi sang `RR Ngày 200` / `RR Chiều 400`. | Cân bằng giữa nhận diện và an toàn. |
| R4 | `id` = slug ASCII không dấu: `rr-vang-200`. `nameVi` có dấu đầy đủ. `nameEn` (nếu cần) = bản dịch nghĩa, không phải tên gốc. | Telex-clean cho code; tiếng Việt chuẩn cho UI. |
| R5 | **Một stock → một preset; không trùng ISO + vibe.** Hai stock cùng ISO nhưng vibe khác thì được (vd RR Vàng 200 ấm rực vs RR Ấm 200 ấm dịu). | Tránh 2 preset cùng vai trò, người dùng không phân biệt được. |
| R6 | `inspired-by` (tên gốc) **chỉ lưu nội bộ** trong JSON/spec, không hiện UI, không hiện App Store metadata/screenshot. | Giữ traceability cho dev, không lộ trademark ra ngoài. |
| R7 | **Tên không hứa hẹn sai:** không dùng từ của hãng khác (không gọi "Chrome", "Velvia", "Kodachrome"), không gọi "Pro" nếu không phải dòng pro. | Tránh nhầm lẫn + tránh trademark chéo. |
| R8 | **Giữ hậu tố chức năng khi cần:** `T` cho tungsten (800T), `BW` cho đen trắng (không có trong bảng này). | `T` là thông tin kỹ thuật, không phải trademark. |
| R9 | **Tier gợi ý theo giá shop + độ phổ biến:** ≤ ~320k = phổ thông → ứng viên Free; ≥ ~350k = chuyên/premium → ứng viên Pro. **Đây là gợi ý, không quyết định tier** — tier cuối theo freemium map đã có (xem §4, có 1 xung đột cần chốt). | Giá shop phản ánh độ "cao cấp" trong mắt người chơi film VN. |
| R10 | **Tên đọc được khi nói, ≤ 3 âm tiết sau prefix.** Test: đọc "R R Vàng 200" phải gọn, không vấp. | Tên stock được nhắc trong reveal + share; tên dài sẽ bị cắt. |

## 2. Thông số — 6 chiều mô tả mỗi stock

Mỗi stock được mô tả bằng 6 chiều, map thẳng sang tham số preset JSON:

| Chiều | Giá trị | Map sang preset |
|---|---|---|
| Nhiệt màu | Ấm / Mát / Trung tính | `temp` (K) + `tint` |
| Bão hòa | Thấp / Vừa / Cao / Rất cao | `sat`, `vib` |
| Tương phản | Thấp / Vừa / Cao | S-curve `s` trong toneCurve |
| Grain | Mịn / Vừa / Rõ | `grain` amount/size |
| Da | Tốt / Trung bình / Kém | `skinProtect` + intensity cap ở scene portrait |
| Đặc trưng | Halation / Light leak / Đỏ rực / Pastel… | `halation`, `lift` đen, tint kênh |

## 3. Bảng 21 stock — tên gốc → tên RR

Giá = VNĐ/cuộn 36 kiểu theo bảng shop gửi (chưa rõ ngày bảng giá).

| # | Stock gốc (nội bộ) | Giá | ISO | Tính chất | Tên RR | id | Tier* |
|---|---|---|---|---|---|---|---|
| 1 | YesStar 200 | 270k | 200 | Ấm vừa, bão hòa vừa, tương phản vừa, grain vừa. Phim TQ giá rẻ, phổ thông ở VN; hãng sx Guangxi Juxing (chưa xác minh emulsion). | **RR Sao Mai 200** | `rr-sao-mai-200` | Free |
| 2 | YesStar 400 | 300k | 400 | Ấm vừa, grain rõ hơn 200, chụp tối tốt hơn. Cùng họ YesStar. | **RR Sao Hôm 400** | `rr-sao-hom-400` | Free |
| 3 | Fuji C200 | 285k | 200 | Mát, ám xanh lá nhẹ, bão hòa vừa, tương phản vừa, grain vừa. | **RR Mát 200** | `rr-mat-200` | Free |
| 4 | Fuji C400 | 320k | 400 | Mát, bão hòa vừa–cao, grain rõ hơn C200. | **RR Gió 400** | `rr-gio-400` | Free |
| 5 | Gold 200 | 260k | 200 | **Ấm vàng**, bão hòa cao, tương phản vừa, grain mịn. Stock quốc dân, rẻ nhất bảng. | **RR Vàng 200** | `rr-vang-200` | Free |
| 6 | ColorPlus 200 | 260k | 200 | Ấm dịu (nhạt hơn Gold), bão hòa vừa, tương phản vừa, grain vừa. | **RR Ấm 200** | `rr-am-200` | Free |
| 7 | Ultramax 400 | 285k | 400 | Ấm, bão hòa cao, tương phản vừa–cao, grain rõ. Đa dụng nhất họ 400 giá rẻ. | **RR Rực 400** | `rr-ruc-400` | Free |
| 8 | KodaColor 100 | 285k | 100 | Ấm hoài cổ, bão hòa vừa–thấp, tương phản thấp–vừa, grain mịn. | **RR Hoài Cổ 100** | `rr-hoai-co-100` | Free |
| 9 | KodaColor 200 | 285k | 200 | Như trên, grain vừa hơn. | **RR Hoài Cổ 200** | `rr-hoai-co-200` | Free |
| 10 | Reto Prism 200 | 360k | 200 | Ấm vintage, bão hòa vừa, tương phản vừa. Có ý kiến cho là Vision3 250D respool — **chưa xác minh**. | **RR Lăng Kính 200** | `rr-lang-kinh-200` | Pro |
| 11 | Reto Prism 400 | 360k | 400 | Như trên, grain rõ hơn, chụp tối tốt hơn. | **RR Lăng Kính 400** | `rr-lang-kinh-400` | Pro |
| 12 | Reto Maple 100 | 360k | 100 | Ấm, đỏ rực + cyan, tương phản thấp–vừa, grain mịn, **light leak** (theo Analogue Wonderland). | **RR Lá Phong 100** | `rr-la-phong-100` | Pro |
| 13 | Proimage 100 | 355k | 100 | Ấm, bão hòa cao, tương phản vừa, grain mịn. Dòng pro daylight. | **RR Nắng 100** | `rr-nang-100` | Pro |
| 14 | Ektar 100 | 470k | 100 | **Bão hòa rất cao, tương phản cao, đỏ rực**, grain mịn nhất. Vivid king. | **RR Rực Rỡ 100** | `rr-ruc-ro-100` | Pro |
| 15 | Portra 160 | 465k | 160 | Ấm pastel, bão hòa thấp–vừa, tương phản thấp, grain mịn, **da tốt nhất**. | **RR Da Mềm 160** | `rr-da-mem-160` | Pro |
| 16 | Portra 400 | 510k | 400 | Ấm tự nhiên, bão hòa vừa, tương phản vừa, grain mịn, da tốt. Đa dụng nhất họ Portra. | **RR Chân Dung 400** | `rr-chan-dung-400` | Free† |
| 17 | Portra 800 | 595k | 800 | Ấm, bão hòa vừa, tương phản vừa, grain rõ, da tốt, chụp tối. | **RR Đêm Mềm 800** | `rr-dem-mem-800` | Pro |
| 18 | Cinestill 800T | 500k | 800T | **Tungsten (vàng đèn), halation, bóng xanh teal**, tương phản vừa–cao, grain rõ, đêm. | **RR Đèn Vàng 800T** | `rr-den-vang-800t` | Pro |
| 19 | Ektacolor Pro 160 | 475k | 160 | Trung tính–ấm, bão hòa vừa, tương phản vừa, grain mịn, **màu chuẩn lab**, da tốt. | **RR Chuẩn 160** | `rr-chuan-160` | Pro |
| 20 | Ektacolor Pro 400 | 525k | 400 | Như trên, grain vừa hơn. | **RR Chuẩn 400** | `rr-chuan-400` | Pro |
| 21 | Ektacolor Pro 800 | 605k | 800 | Như trên, grain rõ, đắt nhất bảng. | **RR Chuẩn 800** | `rr-chuan-800` | Pro |

\* Tier theo R9 (giá shop). † **Xung đột cần chốt:** Portra 400 giá 510k → theo R9 phải là Pro, nhưng freemium map đã chốt từ 01/11 để Portra 400 ở **Free**. Đề xuất giữ Free theo map cũ (Portra 400 là stock quốc dân, cần có ở bản miễn phí để kéo user); R9 chỉ là gợi ý, không override map cũ.

**Tóm tắt tier đề xuất:** Free 10 (Sao Mai 200, Sao Hôm 400, Mát 200, Gió 400, Vàng 200, Ấm 200, Rực 400, Hoài Cổ 100, Hoài Cổ 200, Chân Dung 400) — Pro 11 (còn lại).

## 4. Map với preset đang có (đừng build trùng)

| Tên RR | Preset đã có trong app | Trạng thái |
|---|---|---|
| RR Vàng 200 | `gold-200` (v1 12-pack) | Đã có hướng, chưa tune curve |
| RR Chân Dung 400 | `portra-400` (v1, Free) | Đã có hướng, chưa tune curve |
| RR Da Mềm 160 | `portra-160` (presets-drop-2026, Pro) | Đã có curve curvegen, loop PASS |
| RR Đèn Vàng 800T | `cinestill-800t` (presets-drop-2026, Pro) | Đã có toneCurve, chưa bench |
| RR Rực Rỡ 100 | Hướng vivid (Velvia/Ektar) trong báo cáo trends §8 | Chưa có preset riêng — ứng viên mới |
| RR Mát 200 / RR Gió 400 | `fuji-400h` (presets-drop-2026, Pro) | Fuji-400h là 400H pro, không phải C200/C400 — **không trùng**, nhưng vibe mát gần nhau, cần phân biệt rõ khi tune |
| Còn lại (Sao Mai/Hôm, Ấm, Rực, Hoài Cổ, Lăng Kính, Lá Phong, Nắng, Đêm Mềm, Chuẩn 160/400/800) | Chưa có preset | Ứng viên mới — ưu tiên sau khi 9 preset hiện tại xong |

Lưu ý: 21 tên RR là **lớp identity của cuộn film** (stock picker + reveal),
không phải danh sách preset 1:1. Preset không gắn stock (digicam-flash,
vhs-night, bw-stark, studio-clean…) giữ tên riêng như cũ.

## 5. Chưa rõ — cần xác minh trước khi chốt

1. **Dấu `*` trong bảng giá (13/21 dòng có):** chưa rõ nghĩa. Khả năng cao
   là cận date / hết date / hàng order — cần hỏi shop. Nếu là cận date thì
   stock đó giá rẻ nhưng chất lượng không ổn định → không nên đưa vào Free
   hero (Free hero cần stock ổn định nhất).
2. **YesStar emulsion:** hãng sx là Guangxi Juxing (TQ) theo bao bì; emulsion
   gốc chưa xác minh. Tên `Sao Mai/Sao Hôm` chỉ mô tả vibe ấm phổ thông,
   không claim là film gì.
3. **Reto Prism = Vision3 250D respool?** Chỉ là ý kiến 1 commenter trên
   Instagram, chưa xác minh. Không ghi claim này vào app.
4. **Ngày bảng giá:** ảnh không có ngày — giá có thể đã cũ. Tier R9 dựa trên
   giá này chỉ là gợi ý.
5. **Tên `RR`:** prefix theo yêu cầu user. Nếu `RR` là tên brand/app thì
   prefix này đồng thời là brand — cần chốt ý nghĩa trước khi in lên UI
   (vd "RR" = Roll & Reveal?).

## Nguồn kiểm chứng nhanh (11/11/2026)

- YesStar: bao bì ghi nhà sx Guangxi Juxing Medical Equipment Co. (Threads
  @er_loayhoayvoinhungcuonfilm, 20/03/2026); "YesStar 200 and 400 have been
  the most satisfying substitutes at a fair price" (tahusa.co, Lucky C200
  review, 24/09/2025).
- Reto Prism: commenter trên Instagram cho là "likely Kodak Vision3 250D
  respooled" (chưa xác minh); Retocolor Prism 200/400 là daylight color
  negative C-41 (camerafilmphoto.com, showa-store.com).
- Reto Maple 100: "fine-grained ISO 100… medium to low contrast, captivating
  reds and cyan tones… perfect for bright outdoor lighting… prone to light
  leaks" (analoguewonderland.co.uk).
- Các stock Kodak/Fuji còn lại: tính chất theo hiểu biết chung về film +
  hướng đã chốt trong spec LUT 07/11 và báo cáo trends 10/11 (chưa đo lại
  trên ảnh thật — khi tune preset nào thì đo bằng scorecard/loop trên ảnh đó).
