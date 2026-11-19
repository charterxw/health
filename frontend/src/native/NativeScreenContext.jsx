import { createContext } from 'react'

// A selected history report must not replace the active workout's Live Activity.
// Screen/navigation state is therefore separate from the workout snapshot.
export default createContext(() => {})
