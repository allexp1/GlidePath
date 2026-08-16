/**
 * What drivers reported, emailed to a human.
 *
 * Reports are useless until somebody reads them. They land at status 'pending'
 * and reach no phone by design, which is what makes an anonymous write
 * endpoint acceptable - but it also means the queue is invisible until someone
 * remembers to go and look at it, and nobody remembers.
 *
 * Two rhythms, because reports are not all equally urgent:
 *
 *   - A **daily digest** of everything still pending. One mail a day, not one
 *     per report: the first driver to lean on the button would otherwise turn
 *     this into a spam cannon and the mail would be filtered within a week.
 *   - An **immediate** mail when a single camera collects three independent
 *     reports. One person saying a camera is gone is an opinion; three is
 *     evidence, and evidence about a camera that is warning drivers wrongly
 *     should not wait until morning.
 *
 *   supabase functions deploy report-digest
 *
 * Needs RESEND_API_KEY and REPORT_EMAIL as function secrets. Without them it
 * still runs and returns the digest as JSON, which is deliberate: the queue
 * being readable must not depend on a third party being configured.
 */

import { createClient } from 'npm:@supabase/supabase-js@2'

/// Independent reports about one camera before it stops being an opinion.
///
/// Three rather than two because two is one person tapping twice on the same
/// stretch of road, and rather than five because a camera that is genuinely
/// gone will not collect five reports quickly on a road nobody drives.
const CORROBORATION = 3

interface ReportRow {
  id: string
  kind: string
  country_code: string | null
  created_at: string
  camera_id: string | null
  note: string | null
}

Deno.serve(async (request: Request) => {
  const url = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!url || !serviceRoleKey) {
    return json({ error: 'SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set' }, 500)
  }

  const client = createClient(url, serviceRoleKey, { auth: { persistSession: false } })

  const params = new URL(request.url).searchParams
  const urgentCameraId = params.get('urgent')
  const dryRun = params.get('dryRun') === 'true'

  const { data, error } = await client
    .from('pending_reports')
    .select('id, kind, country_code, created_at, camera_id, note')
    .eq('status', 'pending')
    .order('created_at', { ascending: false })
    .limit(500)

  if (error) {
    return json({ error: `could not read the queue: ${error.message}` }, 500)
  }

  const reports = (data ?? []) as ReportRow[]

  // Grouped by camera, because the interesting unit is "this camera has a
  // problem", not "somebody tapped a button". Ten reports about one camera is
  // one decision to make; ten about ten cameras is ten.
  const byCamera = new Map<string, ReportRow[]>()
  for (const report of reports) {
    const key = report.camera_id ?? `unattached:${report.id}`
    byCamera.set(key, [...(byCamera.get(key) ?? []), report])
  }

  const corroborated = [...byCamera.entries()]
    .filter(([, rows]) => rows.length >= CORROBORATION)
    .map(([cameraId, rows]) => ({ cameraId, count: rows.length, kind: rows[0].kind }))

  const summary = {
    pending: reports.length,
    cameras: byCamera.size,
    corroborated,
    byKind: countBy(reports.map((r) => r.kind)),
    byCountry: countBy(reports.map((r) => r.country_code ?? 'unknown'))
  }

  // An urgent call that is no longer urgent is not worth a mail. The trigger
  // fires on the threshold being crossed, and a human may have cleared the
  // queue in between.
  if (urgentCameraId && !corroborated.some((c) => c.cameraId === urgentCameraId)) {
    return json({ sent: false, reason: 'no longer corroborated', summary })
  }

  if (reports.length === 0) {
    return json({ sent: false, reason: 'nothing pending', summary })
  }

  const subject = urgentCameraId
    ? `Zonexplo: ${CORROBORATION}+ reports on one camera`
    : `Zonexplo: ${reports.length} report${reports.length === 1 ? '' : 's'} waiting`

  const body = renderText(summary, reports, urgentCameraId)

  const apiKey = Deno.env.get('RESEND_API_KEY')
  const to = Deno.env.get('REPORT_EMAIL')
  if (!apiKey || !to) {
    // Not an error. The queue is readable either way, and a missing third
    // party should degrade to "here is the digest" rather than to silence.
    return json({
      sent: false,
      reason: 'RESEND_API_KEY or REPORT_EMAIL is not set; returning the digest instead',
      subject,
      body,
      summary
    })
  }

  if (dryRun) {
    return json({ sent: false, dryRun: true, subject, body, summary })
  }

  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      from: 'Zonexplo <onboarding@resend.dev>',
      to: [to],
      subject,
      text: body
    })
  })

  if (!response.ok) {
    const detail = await response.text()
    return json({ sent: false, error: `resend refused: ${response.status} ${detail}`, summary }, 502)
  }

  return json({ sent: true, subject, summary })
})

function renderText(
  summary: Record<string, unknown>,
  reports: ReportRow[],
  urgentCameraId: string | null
): string {
  const lines: string[] = []

  if (urgentCameraId) {
    lines.push(`Camera ${urgentCameraId} has ${CORROBORATION} or more independent reports.`)
    lines.push('')
  }

  lines.push(`${reports.length} report(s) pending across ${(summary.cameras as number)} camera(s).`)
  lines.push('')

  const corroborated = summary.corroborated as { cameraId: string; count: number; kind: string }[]
  if (corroborated.length > 0) {
    lines.push('-- Worth looking at first --')
    for (const item of corroborated) {
      lines.push(`  ${item.count}x ${item.kind}   camera ${item.cameraId}`)
    }
    lines.push('')
  }

  lines.push('-- By kind --')
  for (const [kind, count] of Object.entries(summary.byKind as Record<string, number>)) {
    lines.push(`  ${count.toString().padStart(4)}  ${kind}`)
  }
  lines.push('')

  lines.push('-- By country --')
  for (const [code, count] of Object.entries(summary.byCountry as Record<string, number>)) {
    lines.push(`  ${count.toString().padStart(4)}  ${code}`)
  }
  lines.push('')

  lines.push('-- Most recent --')
  for (const report of reports.slice(0, 25)) {
    lines.push(
      `  ${report.created_at.slice(0, 16).replace('T', ' ')}  ${report.kind.padEnd(14)}` +
        `${report.country_code ?? '--'}  ${report.camera_id ?? '(no camera)'}` +
        (report.note ? `  "${report.note}"` : '')
    )
  }

  lines.push('')
  lines.push('Nothing here has changed any data. Every row is still pending.')
  lines.push('Approve or reject in the SQL editor:')
  lines.push("  update public.pending_reports set status = 'approved', reviewed_at = now()")
  lines.push("   where id = '...';")

  return lines.join('\n')
}

function countBy(values: string[]): Record<string, number> {
  const counts: Record<string, number> = {}
  for (const value of values) counts[value] = (counts[value] ?? 0) + 1
  return counts
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json' }
  })
}
