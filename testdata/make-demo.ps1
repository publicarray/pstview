# Generates testdata/demo-mailbox: a fictional mailbox (a folder of MBOX files) for screenshots and
# for the cross-platform output check in CI. Everything in it is made up: domains are RFC 2606
# (*.example), IP addresses are RFC 5737 documentation ranges, people and companies are invented.
# Several messages use legacy charsets so that charset decoding is exercised on every platform.
#
#   pwsh testdata/make-demo.ps1
param([string]$Out = (Join-Path $PSScriptRoot "demo-mailbox"))
$ErrorActionPreference = "Stop"
[System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)

function Enc([string]$cs) { [System.Text.Encoding]::GetEncoding($cs) }
function B64([string]$cs, [string]$s) { [Convert]::ToBase64String((Enc $cs).GetBytes($s)) }
# RFC 2047 encoded word
function EW([string]$cs, [string]$s) { "=?${cs}?B?$(B64 $cs $s)?=" }
# base64 body wrapped at 76 columns
function B64Body([string]$cs, [string]$s) {
  $b = B64 $cs ($s -replace "`r", "" -replace "`n", "`r`n")
  ($b -split '(.{76})' | Where-Object { $_ }) -join "`n"
}
# quoted-printable body
function QP([string]$cs, [string]$s) {
  $bytes = (Enc $cs).GetBytes(($s -replace "`r", ""))
  $out = New-Object System.Text.StringBuilder; $col = 0
  foreach ($b in $bytes) {
    if ($b -eq 10) { [void]$out.Append("`n"); $col = 0; continue }
    $t = if ($b -gt 126 -or $b -eq 61) { '={0:X2}' -f $b } else { [string][char]$b }
    if ($col + $t.Length -gt 75) { [void]$out.Append("=`n"); $col = 0 }
    [void]$out.Append($t); $col += $t.Length
  }
  $out.ToString()
}

function Msg($from_line, [string]$text) { "From $from_line`n" + ($text.Trim("`n") -replace "`r", "") + "`n`n" }

$mx = "mx1.northwind.example"

$inbox = @(
(Msg "liam.chen@harbourline.example Wed Oct 21 09:14:05 2026" @"
Return-Path: <liam.chen@harbourline.example>
Received: from mail.harbourline.example (mail.harbourline.example [198.51.100.24])
	by $mx with ESMTPS id 4XK2b8; Wed, 21 Oct 2026 09:14:05 +1100
Received: from [10.20.0.15] (unknown [203.0.113.40])
	by mail.harbourline.example with ESMTPSA id 7Hc1Qe; Wed, 21 Oct 2026 09:14:02 +1100
Authentication-Results: $mx;
	spf=pass smtp.mailfrom=harbourline.example;
	dkim=pass header.d=harbourline.example header.s=sel1;
	dmarc=pass header.from=harbourline.example
DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=harbourline.example; s=sel1;
	h=from:to:subject:date:message-id; bh=ZGVtbyBib2R5IGhhc2g=; b=ZGVtbyBzaWduYXR1cmU=
From: Liam Chen <liam.chen@harbourline.example>
To: Ava Thompson <ava.thompson@northwind.example>
Cc: Operations <ops@northwind.example>
Subject: Q3 freight schedule - revised
Date: Wed, 21 Oct 2026 09:14:00 +1100
Message-ID: <q3-schedule-2026@harbourline.example>
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="mix-q3"

--mix-q3
Content-Type: multipart/alternative; boundary="alt-q3"

--alt-q3
Content-Type: text/plain; charset=utf-8

Hi Ava,

Attached is the revised Q3 schedule. Two changes:

 - Sydney to Auckland moves from Tuesday to Wednesday sailings.
 - Brisbane consolidation now closes at 14:00 instead of 16:00.

Let me know if the new cut-off causes problems for your warehouse team.

Regards,
Liam Chen
Harbourline Freight

--alt-q3
Content-Type: text/html; charset=utf-8

<html><body style="font-family:Segoe UI,Arial,sans-serif">
<p>Hi Ava,</p>
<p>Attached is the revised Q3 schedule. Two changes:</p>
<ul><li>Sydney to Auckland moves from Tuesday to Wednesday sailings.</li>
<li>Brisbane consolidation now closes at <b>14:00</b> instead of 16:00.</li></ul>
<p>Let me know if the new cut-off causes problems for your warehouse team.</p>
<p>Regards,<br>Liam Chen<br><span style="color:#606c80">Harbourline Freight</span></p>
</body></html>

--alt-q3--

--mix-q3
Content-Type: application/pdf; name="Q3-schedule-rev2.pdf"
Content-Disposition: attachment; filename="Q3-schedule-rev2.pdf"
Content-Transfer-Encoding: base64

JVBERi0xLjQKJSBwc3R2aWV3IGRlbW8gYXR0YWNobWVudCAtIG5vdCBhIHJlYWwgc2NoZWR1bGUK
JSVFT0YK

--mix-q3--
"@),
(Msg "billing@payments-harbourline.example.net Thu Oct 22 02:41:19 2026" @"
Return-Path: <billing@payments-harbourline.example.net>
Received: from vps-77.example.net (vps-77.example.net [192.0.2.77])
	by $mx with ESMTP id 9Rt3Lk; Thu, 22 Oct 2026 02:41:19 +1100
Authentication-Results: $mx;
	spf=fail smtp.mailfrom=payments-harbourline.example.net;
	dkim=none;
	dmarc=fail header.from=harbourline.example
From: "Accounts Payable" <accounts@harbourline.example>
Reply-To: <ap-desk@payments-harbourline.example.net>
To: ava.thompson@northwind.example
Subject: URGENT: Invoice INV-20431 overdue - payment details changed
Date: Wed, 21 Oct 2026 15:40:02 +0000
Message-ID: <20261021154002.77@vps-77.example.net>
X-Mailer: Microsoft Outlook 16.0
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

Dear customer,

Invoice INV-20431 is now 14 days overdue. Our bank details have changed;
please use the new account below for this and all future payments:

  Account name: Harbourline Freight Payments
  BSB: 000-000   Account: 00000000

Download the invoice: http://payments-harbourline.example.net/invoice/INV-20431

Payment must be received today to avoid suspension of your account.

Accounts Payable
"@),
(Msg "j.weber@elbe-lager.example Thu Oct 22 18:05:44 2026" @"
Return-Path: <j.weber@elbe-lager.example>
Received: from smtp.elbe-lager.example (smtp.elbe-lager.example [198.51.100.150])
	by $mx with ESMTPS id 2Wq8Zp; Thu, 22 Oct 2026 18:05:44 +1100
Authentication-Results: $mx;
	spf=pass smtp.mailfrom=elbe-lager.example;
	dkim=pass header.d=elbe-lager.example header.s=mail;
	dmarc=pass header.from=elbe-lager.example
From: Jonas Weber <j.weber@elbe-lager.example>
To: Ava Thompson <ava.thompson@northwind.example>
Subject: $(EW "iso-8859-1" "Wareneingang bestätigt - Lieferung 4471")
Date: Thu, 22 Oct 2026 09:05:40 +0200
Message-ID: <4471-wareneingang@elbe-lager.example>
MIME-Version: 1.0
Content-Type: text/plain; charset=iso-8859-1
Content-Transfer-Encoding: quoted-printable

$(QP "iso-8859-1" @"
Guten Tag Frau Thompson,

wir bestätigen den Wareneingang der Lieferung 4471 (12 Paletten).
Die Prüfung ergab keine Schäden; die Ware ist eingelagert.

Mit freundlichen Grüßen
Jonas Weber
Elbe Lager GmbH, Hamburg
"@)
"@),
(Msg "o.smirnova@baltic-cargo.example Fri Oct 23 11:20:31 2026" @"
Return-Path: <o.smirnova@baltic-cargo.example>
Received: from mx.baltic-cargo.example (mx.baltic-cargo.example [203.0.113.88])
	by $mx with ESMTPS id 6Hm2Rd; Fri, 23 Oct 2026 11:20:31 +1100
Authentication-Results: $mx;
	spf=pass smtp.mailfrom=baltic-cargo.example;
	dkim=pass header.d=baltic-cargo.example header.s=k1;
	dmarc=pass header.from=baltic-cargo.example
From: $(EW "windows-1251" "Ольга Смирнова") <o.smirnova@baltic-cargo.example>
To: Ava Thompson <ava.thompson@northwind.example>
Subject: $(EW "windows-1251" "Отчёт о поставках за октябрь")
Date: Fri, 23 Oct 2026 03:20:27 +0300
Message-ID: <oct-report-18@baltic-cargo.example>
MIME-Version: 1.0
Content-Type: text/plain; charset=windows-1251
Content-Transfer-Encoding: base64

$(B64Body "windows-1251" @"
Здравствуйте, Ава!

Направляем отчёт о поставках за октябрь.
Все 18 контейнеров доставлены в срок.

С уважением,
Ольга Смирнова
Балтик Карго
"@)
"@),
(Msg "k.sato@sample-butsuryu.example Mon Oct 26 13:02:09 2026" @"
Return-Path: <k.sato@sample-butsuryu.example>
Received: from mail.sample-butsuryu.example (mail.sample-butsuryu.example [198.51.100.201])
	by $mx with ESMTPS id 1Kp7Vx; Mon, 26 Oct 2026 13:02:09 +1100
Authentication-Results: $mx;
	spf=pass smtp.mailfrom=sample-butsuryu.example;
	dkim=pass header.d=sample-butsuryu.example header.s=s2026;
	dmarc=pass header.from=sample-butsuryu.example
From: $(EW "shift_jis" "佐藤 健") <k.sato@sample-butsuryu.example>
To: Ava Thompson <ava.thompson@northwind.example>
Subject: $(EW "shift_jis" "納品書の送付について")
Date: Mon, 26 Oct 2026 11:02:05 +0900
Message-ID: <nouhinsho-10@sample-butsuryu.example>
MIME-Version: 1.0
Content-Type: text/plain; charset=shift_jis
Content-Transfer-Encoding: base64

$(B64Body "shift_jis" @"
トンプソン様

10月分の納品書をお送りいたします。
ご確認のほどよろしくお願いいたします。

佐藤 健
サンプル物流株式会社
"@)
"@),
(Msg "z.kowalska@wisla-trans.example Tue Oct 27 19:47:51 2026" @"
Return-Path: <z.kowalska@wisla-trans.example>
Received: from poczta.wisla-trans.example (poczta.wisla-trans.example [203.0.113.17])
	by $mx with ESMTPS id 8Fg4Jn; Tue, 27 Oct 2026 19:47:51 +1100
Authentication-Results: $mx;
	spf=pass smtp.mailfrom=wisla-trans.example;
	dkim=pass header.d=wisla-trans.example header.s=default;
	dmarc=pass header.from=wisla-trans.example
From: Zofia Kowalska <z.kowalska@wisla-trans.example>
To: Ava Thompson <ava.thompson@northwind.example>
Subject: $(EW "iso-8859-2" "Dokumenty celne: odprawa w Gdańsku")
Date: Tue, 27 Oct 2026 09:47:46 +0100
Message-ID: <odprawa-gdansk@wisla-trans.example>
MIME-Version: 1.0
Content-Type: text/plain; charset=iso-8859-2
Content-Transfer-Encoding: quoted-printable

$(QP "iso-8859-2" @"
Dzień dobry,

w załączeniu przesyłam dokumenty celne dla odprawy w Gdańsku.
Proszę o potwierdzenie odbioru.

Pozdrawiam
Zofia Kowalska
Wisła Trans
"@)
"@),
(Msg "noah.patel@northwind.example Wed Oct 28 10:12:40 2026" @"
Return-Path: <noah.patel@northwind.example>
Received: from app01.northwind.example (app01.northwind.example [192.0.2.10])
	by $mx with ESMTPS id 3Bn6Ty; Wed, 28 Oct 2026 10:12:40 +1100
Authentication-Results: $mx;
	spf=pass smtp.mailfrom=northwind.example;
	dkim=pass header.d=northwind.example header.s=nw1;
	dmarc=pass header.from=northwind.example
From: Noah Patel <noah.patel@northwind.example>
To: Ava Thompson <ava.thompson@northwind.example>
Subject: Lunch on Friday?
Date: Wed, 28 Oct 2026 10:12:36 +1100
Message-ID: <lunch-friday@northwind.example>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

Hi Ava,

Thai place on George St at 12:30 on Friday? Mia and Liam are in.

Noah
"@),
(Msg "mia.rossi@northwind.example Thu Oct 29 08:30:12 2026" @"
Return-Path: <mia.rossi@northwind.example>
Received: from app01.northwind.example (app01.northwind.example [192.0.2.10])
	by $mx with ESMTPS id 5Cv1Gh; Thu, 29 Oct 2026 08:30:12 +1100
Authentication-Results: $mx;
	spf=pass smtp.mailfrom=northwind.example;
	dkim=pass header.d=northwind.example header.s=nw1;
	dmarc=pass header.from=northwind.example
From: Mia Rossi <mia.rossi@northwind.example>
To: Ava Thompson <ava.thompson@northwind.example>, Noah Patel <noah.patel@northwind.example>
Subject: Carrier review - agenda for Monday
Date: Thu, 29 Oct 2026 08:30:08 +1100
Message-ID: <carrier-review-agenda@northwind.example>
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="mix-cr"

--mix-cr
Content-Type: text/plain; charset=utf-8

Agenda for Monday's carrier review:

 1. On-time performance by lane (Q3)
 2. Damage claims - Elbe Lager and Baltic Cargo
 3. Harbourline schedule change and Brisbane cut-off
 4. Rate review for 2027

Invite attached.
Mia

--mix-cr
Content-Type: text/calendar; charset=utf-8; method=REQUEST; name="invite.ics"
Content-Disposition: attachment; filename="invite.ics"

BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//pstview demo//EN
METHOD:REQUEST
BEGIN:VEVENT
UID:carrier-review-2026@northwind.example
DTSTART:20261101T230000Z
DTEND:20261102T000000Z
SUMMARY:Carrier review
LOCATION:Level 4 boardroom
END:VEVENT
END:VCALENDAR

--mix-cr--
"@)
)

$sent = @(
(Msg "ava.thompson@northwind.example Wed Oct 21 11:02:17 2026" @"
From: Ava Thompson <ava.thompson@northwind.example>
To: Liam Chen <liam.chen@harbourline.example>
Subject: Re: Q3 freight schedule - revised
Date: Wed, 21 Oct 2026 11:02:17 +1100
Message-ID: <re-q3-schedule@northwind.example>
In-Reply-To: <q3-schedule-2026@harbourline.example>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

Thanks Liam. The 14:00 Brisbane cut-off works if we can get the pick list by 10:00.
I'll confirm with the warehouse today.

Ava
"@),
(Msg "ava.thompson@northwind.example Wed Oct 28 09:03:55 2026" @"
From: Ava Thompson <ava.thompson@northwind.example>
To: Zofia Kowalska <z.kowalska@wisla-trans.example>
Subject: Re: Dokumenty celne: odprawa w Gdansku
Date: Wed, 28 Oct 2026 09:03:55 +1100
Message-ID: <re-odprawa@northwind.example>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

Dear Zofia,

Received with thanks - I have forwarded the documents to our customs broker.

Kind regards,
Ava Thompson
Northwind Imports
"@)
)

$drafts = @(
(Msg "ava.thompson@northwind.example Thu Oct 29 16:45:00 2026" @"
From: Ava Thompson <ava.thompson@northwind.example>
To: Mia Rossi <mia.rossi@northwind.example>
Subject: Notes for the carrier review
Date: Thu, 29 Oct 2026 16:45:00 +1100
Message-ID: <draft-carrier-notes@northwind.example>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

- Harbourline: ask about Wednesday sailings capacity
- Elbe Lager: no damage this month, keep as primary
- Check the INV-20431 email with finance - bank change looks suspicious
"@)
)

$junk = @(
(Msg "promo@prize-centre.example.net Sat Oct 24 04:12:33 2026" @"
Return-Path: <promo@prize-centre.example.net>
Received: from unknown (HELO bulk3) ([203.0.113.250])
	by $mx with SMTP id 0Zx9Qa; Sat, 24 Oct 2026 04:12:33 +1100
Authentication-Results: $mx;
	spf=softfail smtp.mailfrom=prize-centre.example.net;
	dkim=none;
	dmarc=none header.from=prize-centre.example.net
From: Prize Centre <promo@prize-centre.example.net>
To: ava.thompson@northwind.example
Subject: Congratulations! You have won a `$1,000 gift card
Date: Fri, 23 Oct 2026 17:12:30 +0000
Message-ID: <win-1000@prize-centre.example.net>
MIME-Version: 1.0
Content-Type: text/html; charset=utf-8

<html><body><h2>You are our lucky winner!</h2>
<p>Claim your gift card within 24 hours: <a href="http://prize-centre.example.net/claim">claim now</a></p>
<img src="http://prize-centre.example.net/t.gif?id=4471" width="1" height="1">
</body></html>
"@),
(Msg "it-support@northwind-mail.example.net Tue Oct 27 06:58:02 2026" @"
Return-Path: <bounce@northwind-mail.example.net>
Received: from mail.northwind-mail.example.net (mail.northwind-mail.example.net [192.0.2.199])
	by $mx with ESMTP id 4Lk8Ws; Tue, 27 Oct 2026 06:58:02 +1100
Authentication-Results: $mx;
	spf=pass smtp.mailfrom=northwind-mail.example.net;
	dkim=none;
	dmarc=none header.from=northwind-mail.example.net
From: "Northwind IT Support" <it-support@northwind-mail.example.net>
To: ava.thompson@northwind.example
Subject: Your mailbox is almost full - verify your account
Date: Mon, 26 Oct 2026 19:57:58 +0000
Message-ID: <quota-warning@northwind-mail.example.net>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

Your mailbox has reached 98% of its quota. Verify your account within 24 hours
to keep receiving email: http://northwind-mail.example.net/verify

Northwind IT Support
"@)
)

$archive = @(
(Msg "people@northwind.example Mon Feb  3 08:00:00 2025" @"
From: Northwind People Team <people@northwind.example>
To: Ava Thompson <ava.thompson@northwind.example>
Subject: Welcome to Northwind Imports
Date: Mon, 3 Feb 2025 08:00:00 +1100
Message-ID: <welcome-ava@northwind.example>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

Welcome aboard, Ava! Your first week's schedule is on the intranet.

The People Team
"@),
(Msg "rates@harbourline.example Mon Dec  1 10:30:00 2025" @"
From: Harbourline Rates <rates@harbourline.example>
To: Ava Thompson <ava.thompson@northwind.example>
Subject: Annual freight rates 2026
Date: Mon, 1 Dec 2025 10:30:00 +1100
Message-ID: <rates-2026@harbourline.example>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

Please find our 2026 rate card below. Rates are valid from 1 January 2026.

  Sydney - Auckland      AUD 1,850 / TEU
  Brisbane - Noumea      AUD 2,100 / TEU

Harbourline Freight
"@)
)

New-Item -ItemType Directory -Force $Out | Out-Null
$files = [ordered]@{ "Inbox.mbox" = $inbox; "Sent.mbox" = $sent; "Drafts.mbox" = $drafts; "Junk.mbox" = $junk; "Archive.mbox" = $archive }
foreach ($k in $files.Keys) {
  $text = ($files[$k] -join "")
  if ($text -match "[^\x00-\x7F]") { throw "$k contains non-ASCII text; encode it" }
  [System.IO.File]::WriteAllBytes((Join-Path $Out $k), [System.Text.Encoding]::ASCII.GetBytes($text))
}
"wrote $($files.Count) mailboxes to $Out"
