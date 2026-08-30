type LogoProps = {
  size?: number;
  compact?: boolean;
  reversed?: boolean;
  className?: string;
};

export function Logo({ size = 32, compact = false, reversed = false, className }: LogoProps) {
  const entry = reversed ? "#F5F1E8" : "#241F1B";
  const total = reversed ? "#6BAE9C" : "#1E5B4F";
  const useCompact = compact || size < 24;

  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      fill="none"
      role="img"
      aria-label="ERPWare"
      className={className}
    >
      {useCompact ? (
        <>
          <rect x="4" y="6" width="14" height="4" rx="2" fill={entry} />
          <rect x="4" y="13" width="20" height="4" rx="2" fill={entry} />
          <rect x="4" y="22" width="24" height="5" rx="2.5" fill={total} />
        </>
      ) : (
        <>
          <rect x="5" y="4" width="13" height="3" rx="1.5" fill={entry} />
          <rect x="5" y="10" width="19" height="3" rx="1.5" fill={entry} />
          <rect x="5" y="16" width="9" height="3" rx="1.5" fill={entry} />
          <rect x="5" y="22" width="22" height="1" rx="0.5" fill={entry} opacity={0.3} />
          <rect x="5" y="25" width="22" height="4" rx="1.5" fill={total} />
        </>
      )}
    </svg>
  );
}

export function Wordmark({
  size = 28,
  reversed = false,
  className,
  showMark = true,
}: LogoProps & { showMark?: boolean }) {
  return (
    <span className={`flex items-center gap-2 ${className ?? ""}`}>
      {showMark ? <Logo size={size} reversed={reversed} /> : null}
      <span
        className="font-serif font-semibold"
        style={{ fontSize: size * 0.72, letterSpacing: "-0.02em" }}
      >
        <span style={{ color: reversed ? "#CFC6B4" : "#241F1B" }}>ERP</span>
        <span style={{ color: reversed ? "#6BAE9C" : "#1E5B4F" }}>Ware</span>
      </span>
    </span>
  );
}
