<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ระบบบันทึกข้อมูลผักและผลไม้ประจำวัน v0.0.3-beta</title>
<link href="https://fonts.googleapis.com/css2?family=Sarabun:wght@300;400&display=swap" rel="stylesheet">
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:'Sarabun',sans-serif;font-weight:300;background:#f5f5f0;color:#444;font-size:14px;line-height:1.9}
  .wrap{max-width:720px;margin:0 auto;padding:40px 24px}
  h1{font-size:16px;font-weight:400;color:#555;border-bottom:1px solid #ddd;padding-bottom:12px;margin-bottom:24px}
  h2{font-size:14px;font-weight:400;color:#666;margin:28px 0 8px}
  p{color:#666;margin-bottom:10px}
  .badge{display:inline-block;font-size:11px;background:#e8e8e8;color:#888;padding:2px 8px;border-radius:2px;margin-right:4px}
  table{width:100%;border-collapse:collapse;font-size:13px;margin:12px 0}
  th{text-align:left;padding:6px 8px;background:#efefef;color:#888;font-weight:400;border:1px solid #e0e0e0}
  td{padding:6px 8px;border:1px solid #e8e8e8;color:#777}
  code{font-family:monospace;background:#efefef;padding:1px 5px;font-size:12px;color:#888}
  .note{background:#fafafa;border-left:2px solid #ddd;padding:10px 14px;margin:16px 0;font-size:13px;color:#888}
  .footer{margin-top:60px;padding-top:16px;border-top:1px solid #e8e8e8;font-size:12px;color:#bbb}
  ul{padding-left:20px;color:#777;margin-bottom:10px}
  li{margin-bottom:4px}
  .status{font-size:12px;color:#bbb}
</style>
</head>
<body>
<div class="wrap">

  <h1>ระบบบันทึกข้อมูลผักและผลไม้ประจำวัน <span class="badge">v0.0.3-beta</span><span class="badge">ยังไม่เสร็จ</span></h1>

  <p>โปรเจคนี้สร้างขึ้นเพื่อใช้ในการบันทึกข้อมูลชนิดผักและผลไม้ที่ซื้อมาในแต่ละวัน เพื่อวิเคราะห์พฤติกรรมการบริโภคเบื้องต้นในระยะยาว โดยในเบื้องต้นรองรับเฉพาะข้อมูลที่กรอกด้วยมือเท่านั้น ยังไม่มีระบบนำเข้าข้อมูลอัตโนมัติ</p>

  <div class="note">หมายเหตุ: โปรเจคนี้อยู่ระหว่างการพัฒนา ฟีเจอร์ส่วนใหญ่ยังไม่พร้อมใช้งาน กรุณาอย่านำไปใช้ใน production</div>

  <h2>สถานะโปรเจค</h2>
  <p class="status">อัปเดตล่าสุด: 14 มีนาคม 2567 — ยังไม่มีการเปลี่ยนแปลงที่สำคัญ</p>
  <ul>
    <li>โมดูลบันทึกผัก — <span style="color:#bbb">ยังไม่เริ่ม</span></li>
    <li>โมดูลบันทึกผลไม้ — <span style="color:#bbb">ยังไม่เริ่ม</span></li>
    <li>ระบบ export CSV — <span style="color:#bbb">วางแผนไว้</span></li>
    <li>หน้า dashboard — <span style="color:#bbb">วางแผนไว้</span></li>
    <li>unit test — <span style="color:#bbb">ไม่มีแผน</span></li>
  </ul>

  <h2>โครงสร้างไฟล์ (ยังไม่ครบ)</h2>
  <table>
    <tr><th>ไฟล์</th><th>หน้าที่</th><th>สถานะ</th></tr>
    <tr><td><code>main.py</code></td><td>จุดเริ่มต้นโปรแกรม</td><td>ว่างเปล่า</td></tr>
    <tr><td><code>db.py</code></td><td>เชื่อมต่อฐานข้อมูล</td><td>ยังไม่เขียน</td></tr>
    <tr><td><code>models.py</code></td><td>โครงสร้างข้อมูล</td><td>ยังไม่เขียน</td></tr>
    <tr><td><code>requirements.txt</code></td><td>รายการ dependencies</td><td>ว่างเปล่า</td></tr>
    <tr><td><code>README.md</code></td><td>เอกสารนี้</td><td>กำลังเขียน</td></tr>
  </table>

  <h2>ความต้องการของระบบ</h2>
  <ul>
    <li>Python 3.8 ขึ้นไป (ยังไม่ได้ทดสอบกับเวอร์ชันอื่น)</li>
    <li>SQLite 3 (ยังไม่แน่ใจว่าจะใช้หรือเปล่า อาจเปลี่ยนเป็น JSON ก็ได้)</li>
    <li>ไม่มี dependency อื่น ณ ตอนนี้</li>
  </ul>

  <h2>วิธีติดตั้ง</h2>
  <p>ยังไม่มีขั้นตอนการติดตั้ง เนื่องจากโปรแกรมยังทำงานไม่ได้</p>

  <h2>การใช้งาน</h2>
  <p>ยังไม่สามารถใช้งานได้ในขณะนี้</p>

  <h2>ปัญหาที่รู้อยู่แล้ว</h2>
  <ul>
    <li>ทุกอย่างยังไม่ทำงาน</li>
    <li>ไม่มี error handling</li>
    <li>ยังไม่ได้ตัดสินใจว่าจะใช้ฐานข้อมูลอะไร</li>
    <li>ชื่อตัวแปรในโค้ดยังไม่สอดคล้องกัน</li>
    <li>ยังไม่มีโค้ด</li>
  </ul>

  <h2>License</h2>
  <p>ยังไม่ได้เลือก license อาจจะเป็น MIT หรืออาจจะไม่มีก็ได้</p>

  <h2>ผู้พัฒนา</h2>
  <p>คนเดียว ทำคนเดียว ยังไม่รับ contribution เพราะยังไม่มีอะไรให้ contribute</p>

  <div class="footer">
    ระบบบันทึกข้อมูลผักและผลไม้ประจำวัน — โปรเจคส่วนตัวที่ไม่มีประโยชน์ต่อสาธารณะ<br>
    หากมีคำถามกรุณาอย่าถาม เพราะยังไม่มีคำตอบ
  </div>

</div>
</body>
</html>
