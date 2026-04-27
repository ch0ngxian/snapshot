import * as admin from "firebase-admin";
import { setGlobalOptions } from "firebase-functions/v2";

admin.initializeApp();

// Global defaults — region per tech-plan.md §5.4 (locked to asia-southeast1).
setGlobalOptions({ region: "asia-southeast1", maxInstances: 10 });

export { deleteUserData } from "./deleteUserData";
export { createLobby } from "./createLobby";
export { joinLobby } from "./joinLobby";
