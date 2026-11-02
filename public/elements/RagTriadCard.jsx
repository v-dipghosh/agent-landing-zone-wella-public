import React from "react";

const labels = {
  groundedness: "Groundedness",
  relevance: "Answer relevance",
  retrieval: "Retrieval quality",
};

const descriptions = {
  groundedness: "Is the answer supported by the retrieved evidence?",
  relevance: "Does the answer address the question?",
  retrieval: "How useful is the retrieved evidence for the question?",
};

const metricOrder = Object.keys(labels);

export default function RagTriadCard() {
  const metrics = [...props.metrics].sort(
    (left, right) => metricOrder.indexOf(left.metric) - metricOrder.indexOf(right.metric)
  );

  return (
    <div className="rag-triad" aria-label="RAG answer evaluations">
      <h2 className="rag-triad-heading">Answer quality</h2>
      {metrics.map((metric) => (
        <section className="wella-groundedness" key={metric.metric} aria-label={labels[metric.metric]}>
          <div className="wella-groundedness-heading">
            <h3>{labels[metric.metric]}</h3>
            <span>
              {metric.status === "success" ? `${metric.score.toFixed(1)}/5` : "Unavailable"}
            </span>
          </div>
          <p className="wella-groundedness-provider">Microsoft Azure AI Evaluation</p>
          <p className="rag-triad-description">{descriptions[metric.metric]}</p>
          {metric.status === "success" && (
            <>
              <progress
                max={1}
                value={metric.score / 5}
                aria-label={`${labels[metric.metric]}: ${metric.score} out of 5`}
              />
              <p className="rag-triad-normalized">
                {(metric.score / 5 * 100).toFixed(0)}% normalized score · Not a probability of accuracy
              </p>
            </>
          )}
          <details>
            <summary>{metric.status === "success" ? "Why this score?" : "Why unavailable?"}</summary>
            <p className="rag-triad-reason">{metric.reason}</p>
          </details>
        </section>
      ))}
      {props.evidence_truncated && (
        <p className="rag-triad-note">
          Groundedness and retrieval were evaluated using a truncated evidence window.
        </p>
      )}
      <p className="rag-triad-note">
        Model-based scores are quality signals, not guarantees of correctness.
      </p>
    </div>
  );
}
