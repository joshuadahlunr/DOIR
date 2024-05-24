#include "doctest.h"

#define FP_IMPLEMENTATION
#include "../fp/pointer.h"
#include "../fp/dynarray.h"
#include "../fp/bitmask.h"

TEST_SUITE("LibFP") {

	TEST_CASE("Stack") {
		int* arr = fp_salloc(int, 20);
		arr[10] = 6;

		CHECK(is_fp(arr) == true);
		CHECK(fp_length(arr) == 20);
		CHECK(arr[10] == 6);
	}

	TEST_CASE("Heap") {
		int* arr = fp_malloc(int, 20);
		arr = fp_realloc(int, arr, 25);
		arr[20] = 6;

		CHECK(is_fp(arr) == true);
		CHECK(fp_length(arr) == 25);
		CHECK(arr[20] == 6);

		fp_free(arr);
	}

	TEST_CASE("View") {
		int* arr = fp_salloc(int, 20);
		arr[10] = 6;

		auto view = fp_view_make(arr, 10, 3);
		CHECK(fp_view_size(view) == 3);
		CHECK(*fp_view_access(view, 0) == 6);
		*fp_view_access(view, 1) = 6;
		*fp_view_access(view, 2) = 6;

		fp_view_iterate(view) CHECK(*i == 6);
	}

	TEST_CASE("Dynamic Array - Basic") {
		fp_dynarray(int) arr = nullptr;
		fpda_reserve(arr, 20);
		CHECK(fpda_capacity(arr) == 0); // NOTE: FPDAs aren't valid until they have had at least one element added!
		CHECK(fpda_size(arr) == 0);

		fpda_push_back(arr, 5);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_size(arr) == 1);
		CHECK(arr[0] == 5);

		fpda_push_front(arr, 6);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_size(arr) == 2);
		CHECK(arr[0] == 6);
		CHECK(arr[1] == 5);
		CHECK(*fpda_front(arr) == 6);
		CHECK(*fpda_back(arr) == 5);

		fpda_push_back(arr, 7);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_size(arr) == 3);
		CHECK(arr[0] == 6);
		CHECK(arr[1] == 5);
		CHECK(arr[2] == 7);
		CHECK(*fpda_front(arr) == 6);
		CHECK(*fpda_back(arr) == 7);

		fpda_delete(arr, 1);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_size(arr) == 2);
		CHECK(arr[0] == 6);
		CHECK(arr[1] == 7);

		fpda_swap(arr, 0, 1);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_size(arr) == 2);
		CHECK(arr[0] == 7);
		CHECK(arr[1] == 6);

		fp_dynarray(int) arr2 = nullptr;
		fpda_clone(arr2, arr);
		CHECK(arr2 != arr);
		CHECK(fpda_capacity(arr) == 20);
		CHECK(fpda_capacity(arr2) == 20);
		CHECK(fpda_size(arr) == 2);
		CHECK(fpda_size(arr2) == 2);
		CHECK(arr[0] == 7);
		CHECK(arr2[0] == 7);
		CHECK(arr[1] == 6);
		CHECK(arr2[1] == 6);

		fpda_shrink_to_fit(arr);
		CHECK(fpda_capacity(arr) == 2);
		CHECK(fpda_size(arr) == 2);
		CHECK(arr[0] == 7);
		CHECK(arr[1] == 6);

		fpda_free(arr);
		fpda_free(arr2);
	}

	TEST_CASE("Dynamic Array - Miscellaneous") {
		fp_dynarray(int) arr = nullptr;
		for(size_t i = 0; i < 5; i++) {
			fpda_push_back(arr, i);
			CHECK(arr[i] == i);
		}


		SUBCASE("fpda_grow_to_size") {
			fpda_grow_to_size(arr, 5);
			CHECK(fpda_capacity(arr) == 8); // NOTE: Resize can't shrink... it can only grow
			CHECK(fpda_size(arr) == 5);
			CHECK(arr[0] == 0);
			CHECK(arr[4] == 4);
		}
		SUBCASE("fpda_grow") {
			fpda_grow(arr, 5);
			CHECK(fpda_capacity(arr) == 16);
			CHECK(fpda_size(arr) == 10);
			CHECK(arr[0] == 0);
			CHECK(arr[4] == 4);
		}
		SUBCASE("fpda_pop_back") {
			fpda_pop_back(arr);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 4);
			CHECK(arr[0] == 0);
			CHECK(arr[3] == 3);
		}
		SUBCASE("fpda_insert") {
			fpda_insert(arr, 3, 5);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 6);
			CHECK(arr[0] == 0);
			CHECK(arr[2] == 2);
			CHECK(arr[3] == 5);
			CHECK(arr[4] == 3);
			CHECK(arr[5] == 4);
		}
		SUBCASE("fpda_insert_uninitialized") {
			fpda_insert_uninitialized(arr, 3, 3);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 8);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 1);
			CHECK(arr[2] == 2);
			CHECK(arr[3] == 3); // NOTE: Uninitialized -> whatever was there before is still there!
			CHECK(arr[4] == 4); // NOTE: Uninitialized -> whatever was there before is still there!
			CHECK(arr[5] == 0); // NOTE: Uninitialized -> whatever was there before is still there!
			CHECK(arr[6] == 3);
			CHECK(arr[7] == 4);
		}
		SUBCASE("fpda_delete_range") {
			fpda_delete_range(arr, 2, 2);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 3);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 1);
			CHECK(arr[2] == 4);
		}
		SUBCASE("fpda_delete_start_end") {
			fpda_delete_start_end(arr, 1, 3);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 2);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 4);
		}
		// SUBCASE("fpda_shrink_delete_range") {
		// 	fpda_shrink_delete_range(arr, 2, 2);
		// 	CHECK(fpda_capacity(arr) == 3);
		// 	CHECK(fpda_size(arr) == 3);
		// 	CHECK(arr[0] == 0);
		// 	CHECK(arr[2] == 4);
		// }
		SUBCASE("fpda_shrink_delete") {
			fpda_shrink_delete(arr, 3);
			CHECK(fpda_capacity(arr) == 4);
			CHECK(fpda_size(arr) == 4);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 1);
			CHECK(arr[2] == 2);
			CHECK(arr[3] == 4);
		}
		// SUBCASE("fpda_shrink_delete_start_end") {
		// 	fpda_shrink_delete_start_end(arr, 1, 3);
		// 	CHECK(fpda_capacity(arr) == 2);
		// 	CHECK(fpda_size(arr) == 2);
		// 	CHECK(arr[0] == 0);
		// 	CHECK(arr[1] == 4);
		// }
		SUBCASE("fpda_resize (grow)") {
			fpda_resize(arr, 10);
			CHECK(fpda_capacity(arr) == 10);
			CHECK(fpda_size(arr) == 10);
			CHECK(arr[0] == 0);
			CHECK(arr[4] == 4);
		}
		SUBCASE("fpda_resize (shrink)") {
			fpda_resize(arr, 3);
			CHECK(fpda_capacity(arr) == 3);
			CHECK(fpda_size(arr) == 3);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 1);
			CHECK(arr[2] == 2);
		}
		SUBCASE("fpda_swap_range 1") {
			fpda_swap_range(arr, 1, 3, 1);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 5);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 3);
			CHECK(arr[2] == 2);
			CHECK(arr[3] == 1);
			CHECK(arr[4] == 4);
		}
		SUBCASE("fpda_swap_range 2") {
			fpda_swap_range(arr, 1, 3, 2);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 5);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 3);
			CHECK(arr[2] == 4);
			CHECK(arr[3] == 1);
			CHECK(arr[4] == 2);
		}
		// SUBCASE("fpda_swap_delete_range") {
		// 	fpda_swap_delete_range(arr, 2, 2);
		// 	CHECK(fpda_capacity(arr) == 8);
		// 	CHECK(fpda_size(arr) == 3);
		// 	CHECK(arr[0] == 0);
		// 	CHECK(arr[1] == 1);
		// 	CHECK(arr[2] == 4);
		// 	// CHECK(arr[3] == 4);
		// 	// CHECK(arr[4] == 4);
		// }
		SUBCASE("fpda_swap_delete") {
			fpda_swap_delete(arr, 3);
			CHECK(fpda_capacity(arr) == 8);
			CHECK(fpda_size(arr) == 4);
			CHECK(arr[0] == 0);
			CHECK(arr[1] == 1);
			CHECK(arr[2] == 2);
			CHECK(arr[3] == 4);
			// CHECK(arr[4] == 4);
		}
		// SUBCASE("fpda_swap_delete_start_end") {
		// 	fpda_swap_delete_start_end(arr, 1, 3);
		// 	CHECK(fpda_capacity(arr) == 8);
		// 	CHECK(fpda_size(arr) == 2);
		// 	CHECK(arr[0] == 0);
		// 	CHECK(arr[1] == 4);
		// 	// CHECK(arr[2] == 3);
		// 	// CHECK(arr[3] == 4);
		// 	// CHECK(arr[4] == 4);
		// }

		fpda_free(arr);
	}

	TEST_CASE("Bitmask") {
		fp_bitmask_t mask = nullptr;
		fp_bitmask_init(mask);
		CHECK(fp_bitmask_find_highest_set(mask) == 0);
		auto s = fp_bitmask_to_string(mask);
		CHECK(strcmp(s, "0") == 0);
		// puts(s);
		fpda_free(s);

		fp_bitmask_set(mask, 5);
		fp_bitmask_set(mask, 6);
		fp_bitmask_set(mask, 7);
		CHECK(fp_bitmask_find_highest_set(mask) == 7);
		CHECK(strcmp(s = fp_bitmask_to_string(mask), "11100000") == 0);
		// puts(s);
		fpda_free(s);

		fp_bitmask_reset(mask, 6);
		CHECK(fp_bitmask_find_highest_set(mask) == 7);
		CHECK(strcmp(s = fp_bitmask_to_string(mask), "10100000") == 0);
		// puts(s);
		fpda_free(s);

		fp_bitmask_set(mask, 60);
		fp_bitmask_set(mask, 61);
		CHECK(fp_bitmask_find_highest_set(mask) == 61);
		CHECK(strcmp(s = fp_bitmask_to_string(mask), "11000000000000000000000000000000000000000000000000000010100000") == 0);
		// puts(s);
		fpda_free(s);
		CHECK(strcmp(s = fp_bitmask_to_string_extended(mask, 0, 10), "0010100000") == 0);
		// puts(s);
		fpda_free(s);

		fp_bitmask_free(mask);
	}

	TEST_CASE("Bitmask Round-Trip") {
		fp_bitmask_t mask = nullptr;
		fp_bitmask_init(mask);

		char* str = (char*)"100110", *res;
		fp_bitmask_from_binary_string(mask, str);
		CHECK(fp_bitmask_test(mask, 0) == false);
		CHECK(fp_bitmask_test(mask, 1) == true);
		CHECK(fp_bitmask_test(mask, 2) == true);
		CHECK(fp_bitmask_test(mask, 3) == false);
		CHECK(fp_bitmask_test(mask, 4) == false);
		CHECK(fp_bitmask_test(mask, 5) == true);
		CHECK(fp_bitmask_test(mask, 6) == false); // One more for good measure!
		CHECK(fp_bitmask_find_highest_set(mask) == 5);
		CHECK(strcmp(res = fp_bitmask_to_string(mask), str) == 0);
		// puts(res);

		fpda_free(res);
		fp_bitmask_free(mask);
	}

}