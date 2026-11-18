import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import LiveSubsShowcase from './livesubs'
import './page.css'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <main className="page">
      <div id="showcase" className="page__demo">
        <LiveSubsShowcase />
      </div>
    </main>
  </StrictMode>,
)
