const confidenceLabels = { low: '有限', medium: '中等', high: '较充分' }

export default function Observation({ insight }) {
  const report = insight?.report
  if (!report) {
    // Keep historical reports accessible without showing the former long template by default.
    return <details className="text-sm text-[var(--text-secondary)]">
      <summary className="cursor-pointer">查看旧版分析</summary>
      <p className="mt-3 whitespace-pre-wrap leading-relaxed">{insight?.content}</p>
    </details>
  }
  return <div className="space-y-4">
    {report.findings?.map((finding, index) => <article key={index}>
      <h4 className="text-[16px] leading-snug font-semibold">{finding.headline}</h4>
      <p className="mt-2 text-[14px] leading-relaxed text-[var(--text)]">{finding.body}</p>
      <details className="mt-3 text-[12px] text-[var(--text-secondary)]">
        <summary className="cursor-pointer w-fit">查看依据</summary>
        <ul className="mt-2 space-y-1.5 list-disc pl-4 leading-relaxed">
          {finding.evidence.map((line, i) => <li key={i}>{line}</li>)}
        </ul>
        <p className="mt-2">证据强度：{confidenceLabels[finding.confidence] || finding.confidence}</p>
        {report.limitations && <p className="mt-2 leading-relaxed">{report.limitations}</p>}
      </details>
    </article>)}
    {!report.findings?.length && <p className="text-[14px] leading-relaxed">{report.summary}</p>}
    {!report.findings?.length && report.limitations && <details className="text-[12px] text-[var(--text-secondary)]">
      <summary className="cursor-pointer">查看依据</summary>
      <p className="mt-2">{report.limitations}</p>
    </details>}
  </div>
}
