#!/usr/bin/env python3.12
"""Plot mjj distribution from merge_ss_*.root."""
import sys, os, argparse
import uproot, numpy as np

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
except ImportError:
    print("matplotlib not available, install via pip3.12")
    sys.exit(1)

parser = argparse.ArgumentParser()
parser.add_argument('input', nargs='+', help='merge_ss_*.root files')
parser.add_argument('-o', '--output', default='mjj.pdf', help='Output plot path')
parser.add_argument('--title', default=None)
args = parser.parse_args()

mjj = []
for fname in args.input:
    if not os.path.exists(fname):
        print(f"WARNING: {fname} not found, skipping")
        continue
    with uproot.open(fname) as f:
        t = f['tree']
        mjj.extend(t['mjj'].array().tolist())

mjj = np.array(mjj)
if len(mjj) == 0:
    print("ERROR: No mjj entries found")
    sys.exit(1)

fig, ax = plt.subplots(figsize=(8, 5))
ax.hist(mjj, bins=40, range=(50, 200), histtype='step', color='black', linewidth=1.5)
ax.set_xlabel('mjj [GeV]')
ax.set_ylabel(f'Events / {150/40:.1f} GeV')
ax.set_title(args.title or f'Dijet invariant mass ({len(mjj)} events)')

# Add peak annotation
mean, std = np.mean(mjj), np.std(mjj)
ax.axvline(125, color='red', linestyle='--', alpha=0.5, label='mH = 125 GeV')
ax.text(0.02, 0.95, f'Mean: {mean:.1f} GeV\nRMS: {std:.1f} GeV',
        transform=ax.transAxes, va='top', fontsize=9,
        bbox=dict(boxstyle='round', facecolor='white', alpha=0.8))

ax.legend(fontsize=8)
fig.tight_layout()
fig.savefig(args.output)
print(f"Saved {args.output} (entries={len(mjj)}, mean={mean:.1f}, rms={std:.1f})")
plt.close()
