import { useMemo, useState } from 'react'
import {
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table'
import { useStore } from '../../store/useStore'
import type { Position } from '../../types'

const ch = createColumnHelper<Position>()

function f$(v: number | null | undefined) {
  if (v == null) return '--'
  return '$' + Number(v).toFixed(2)
}

const columns = [
  ch.display({
    id: 'select',
    header: '',
    cell: ({ row }) => {
      const { selectedIds, toggleSelected } = useStore.getState()
      return (
        <input
          type="checkbox"
          checked={selectedIds.has(row.original.id)}
          onChange={() => toggleSelected(row.original.id)}
          onClick={(e) => e.stopPropagation()}
        />
      )
    },
    size: 32,
    enableSorting: false,
  }),
  ch.accessor('underlying', { header: 'Sym', cell: (i) => <b>{i.getValue()}</b>, size: 54 }),
  ch.accessor('display_qty', {
    header: 'Qty',
    cell: (i) => <span style={{ color: i.getValue() < 0 ? 'var(--red)' : 'var(--green)' }}>{i.getValue()}</span>,
    size: 40,
  }),
  ch.accessor('option_type', {
    header: 'Type',
    cell: (i) => <span style={{ color: i.getValue() === 'C' ? 'var(--accent)' : 'var(--red)' }}>{i.getValue() === 'C' ? 'CALL' : 'PUT'}</span>,
    size: 50,
  }),
  ch.accessor('expiration', { header: 'Exp', cell: (i) => <span style={{ color: 'var(--muted)' }}>{i.getValue()}</span>, size: 94 }),
  ch.accessor('strike', { header: 'Strike', size: 64 }),
  ch.accessor('mark', { header: 'Mark', cell: (i) => f$(i.getValue()), size: 70 }),
  ch.accessor('trade_price', { header: 'Trade', cell: (i) => f$(i.getValue()), size: 70 }),
  ch.accessor('pnl_open', {
    header: 'P/L',
    cell: (i) => <span style={{ color: i.getValue() >= 0 ? 'var(--green)' : 'var(--red)' }}>{f$(i.getValue())}</span>,
    size: 76,
  }),
  ch.accessor('short_value', { header: 'ShtVal', cell: (i) => f$(i.getValue()), size: 76 }),
  ch.accessor('long_cost',   { header: 'LngCost', cell: (i) => f$(i.getValue()), size: 76 }),
  ch.accessor('limit_impact', {
    header: 'Impact',
    cell: (i) => <span style={{ color: 'var(--warn)' }}>{f$(i.getValue())}</span>,
    size: 76,
  }),
]

export function PositionsTile() {
  const { positions, positionsLoading, positionsError } = useStore()
  const [sorting, setSorting] = useState<SortingState>([])

  // Flatten groups into rows with group header rows injected
  const flatRows = useMemo(() => {
    const groups: Record<string, Position[]> = {}
    positions.forEach((p) => {
      const k = `${p.underlying}||${p.group ?? ''}`
      if (!groups[k]) groups[k] = []
      groups[k].push(p)
    })
    return groups
  }, [positions])

  const table = useReactTable({
    data: positions,
    columns,
    state: { sorting },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  })

  if (positionsLoading) return <div className="tile" style={{ height: '100%' }}><div className="tile-hdr"><span className="tile-title">Open Positions</span></div><div className="loading">Loading...</div></div>

  return (
    <div className="tile" style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
      <div className="tile-hdr">
        <span className="tile-title">Open Positions</span>
        <span style={{ fontSize: 10, color: 'var(--muted)', marginLeft: 4 }}>{positions.length} legs</span>
      </div>

      {positionsError && <div className="error-msg">{positionsError}</div>}

      <div className="tile-body tbl-wrap">
        <table className="data-table">
          <thead>
            {table.getHeaderGroups().map((hg) => (
              <tr key={hg.id}>
                {hg.headers.map((h) => (
                  <th
                    key={h.id}
                    style={{ width: h.getSize(), cursor: h.column.getCanSort() ? 'pointer' : 'default' }}
                    className={
                      h.column.getIsSorted() === 'asc' ? 'sort-asc' :
                      h.column.getIsSorted() === 'desc' ? 'sort-desc' : ''
                    }
                    onClick={h.column.getToggleSortingHandler()}
                  >
                    {flexRender(h.column.columnDef.header, h.getContext())}
                  </th>
                ))}
              </tr>
            ))}
          </thead>
          <tbody>
            {positions.length === 0 ? (
              <tr><td colSpan={12} className="empty-msg">No positions loaded</td></tr>
            ) : (
              (() => {
                const seen = new Set<string>()
                const rows: JSX.Element[] = []
                table.getRowModel().rows.forEach((row) => {
                  const p = row.original
                  const gk = `${p.underlying}||${p.group ?? ''}`
                  if (!seen.has(gk)) {
                    seen.add(gk)
                    rows.push(
                      <tr key={`g-${gk}`} className="group-row">
                        <td colSpan={12}>
                          {p.underlying}{p.group ? ` \u2014 ${p.group}` : ''}
                        </td>
                      </tr>
                    )
                  }
                  rows.push(
                    <tr key={row.id}>
                      {row.getVisibleCells().map((cell) => (
                        <td key={cell.id}>{flexRender(cell.column.columnDef.cell, cell.getContext())}</td>
                      ))}
                    </tr>
                  )
                })
                return rows
              })()
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
