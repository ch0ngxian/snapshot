/**
 * Unit test for deleteUserData. We don't bring up the emulator here — we
 * verify the auth contract (callable rejects unauthenticated requests) and
 * the result shape on the happy path with a mocked admin SDK.
 *
 * A full emulator-backed integration test is a follow-up once the Firebase
 * project is created (Phase 0 manual followup).
 */

import { CallableRequest, HttpsError } from "firebase-functions/v2/https";

const deleteFn = jest.fn();
const updateFn = jest.fn();
const collectionGroupGet = jest.fn();
const fileDelete = jest.fn();

jest.mock("firebase-admin", () => ({
  initializeApp: jest.fn(),
  firestore: () => ({
    doc: () => ({ delete: deleteFn }),
    collectionGroup: () => ({ where: () => ({ get: collectionGroupGet }) }),
  }),
  storage: () => ({
    bucket: () => ({
      file: () => ({ delete: fileDelete }),
    }),
  }),
}));

// Importing AFTER the mock so initializeApp() in src/index.ts uses the mock.
import { deleteUserData } from "../src/deleteUserData";

const callableHandler = (deleteUserData as unknown as {
  run: (req: CallableRequest<unknown>) => Promise<unknown>;
}).run;

const fakeAuth = (uid: string) =>
  ({
    auth: { uid, token: {} },
    data: undefined,
    rawRequest: {},
    acceptsStreaming: false,
  }) as unknown as CallableRequest<unknown>;

describe("deleteUserData", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    deleteFn.mockResolvedValue(undefined);
    updateFn.mockResolvedValue(undefined);
    fileDelete.mockResolvedValue(undefined);
    collectionGroupGet.mockResolvedValue({ docs: [] });
  });

  test("rejects unauthenticated callers", async () => {
    const unauth = {
      data: undefined,
      rawRequest: {},
      acceptsStreaming: false,
    } as unknown as CallableRequest<unknown>;
    await expect(callableHandler(unauth)).rejects.toBeInstanceOf(HttpsError);
    await expect(callableHandler(unauth)).rejects.toMatchObject({
      code: "unauthenticated",
    });
  });

  test("returns expected shape when user has no tags", async () => {
    const result = (await callableHandler(fakeAuth("user-123"))) as {
      uid: string;
      userDocDeleted: boolean;
      selfieDeleted: boolean;
      tagPhotosCleared: number;
    };
    expect(result).toEqual({
      uid: "user-123",
      userDocDeleted: true,
      selfieDeleted: true,
      tagPhotosCleared: 0,
    });
  });

  test("clears photoStorageRef and deletes photos for tagged docs", async () => {
    const docRef = { update: updateFn };
    collectionGroupGet.mockResolvedValueOnce({
      docs: [
        {
          ref: docRef,
          data: () => ({ photoStorageRef: "tags/lobby1/tag1.jpg" }),
        },
        {
          ref: docRef,
          data: () => ({ photoStorageRef: null }),
        },
      ],
    });

    const result = (await callableHandler(fakeAuth("user-456"))) as {
      tagPhotosCleared: number;
    };

    expect(result.tagPhotosCleared).toBe(2);
    expect(updateFn).toHaveBeenCalledTimes(2);
    expect(updateFn).toHaveBeenCalledWith({ photoStorageRef: null });
    // 1 selfie delete + 1 tag-photo delete (the second tag has a null ref).
    expect(fileDelete).toHaveBeenCalledTimes(2);
  });
});
